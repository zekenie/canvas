# The plugin system

Everything on the canvas comes from a plugin: sticky notes, ellipses, arrows, task cards,
validation, checklists, titles, the pills and chips shown on shapes (adornments), the detail panel
and the table of contents beside the canvas, selecting itself, copying and pasting, locking, the
ports arrows are dragged from, what each key does, what the command line can do, the language model plugins ask, even the examples.
The core (`Sources/Canvas`) knows how to hold shapes, run tools, draw, and wire plugins together,
and nothing about any particular shape or concern. Its one built-in tool is tldraw's Hand, which
pans (a flung release slides on). Select, which selects (a click, ⇧-click, or a marquee dragged
across empty canvas), moves the selection, and drives handles and editing for whatever kinds offer
them, comes from [the Selection plugin](#selection).

This is the same system as data-canvas's `definePlugin`, in Swift. [The last section](#coming-from-data-canvas)
maps one onto the other.

- [Four nouns](#four-nouns)
- [Your first plugin](#your-first-plugin)
- [I want to…](#i-want-to)
- [Horizontal and vertical](#horizontal-and-vertical)
- [The module graph](#the-module-graph)
- [A vertical plugin](#a-vertical-plugin)
- [Tools and sessions](#tools-and-sessions)
- [A shape without a frame](#a-shape-without-a-frame)
- [A horizontal plugin](#a-horizontal-plugin)
- [Properties](#properties)
- [Selection](#selection)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [The detail panel](#the-detail-panel)
- [Context menus](#context-menus)
- [The table of contents](#the-table-of-contents)
- [Adornments](#adornments)
- [The clipboard](#the-clipboard)
- [Locking](#locking)
- [Ports](#ports)
- [Mentions](#mentions)
- [The command line](#the-command-line)
- [Schema cards](#schema-cards)
- [Language models](#language-models)
- [Capabilities](#capabilities)
- [The editor, the document, and drawing](#the-editor-the-document-and-drawing)
- [Undo](#undo)
- [Boards on disk](#boards-on-disk)
- [The registry](#the-registry)
- [Testing plugins](#testing-plugins)
- [Coming from data-canvas](#coming-from-data-canvas)
- [Not built yet](#not-built-yet)

## Four nouns

| | What it is | Example |
|---|---|---|
| **Kind** | A plain value type holding a shape's data, defined by its list of properties. It names itself once, with `static let kind`. | `struct StickyNote: BoxShapeProps { frame, text }` |
| **Definition** | Stateless behavior for a kind: how it draws, where it is, how it's hit, what else it can do. | `StickyNoteDefinition`, conforming to `ShapeDefinition` and `Editable` |
| **Plugin** | A value that says what it adds, in `register(into:)`. | `struct StickyNotesPlugin: CanvasPlugin` |
| **Extension point** | A typed slot some plugin declares and other plugins fill. The type is the key. | `enum ValidationRules: ExtensionPoint` |

Two more things hold them together:

- The **registry** is built once from the plugin list, checked (every collision is an error), and
  then frozen.
- The **editor** (`CanvasEditor`) is the headless brain: the document, the camera, tools,
  sessions, input and drawing. `CanvasView` only turns `NSEvent`s into editor calls, through a host
  API that plugins can't see.

## Your first plugin

[Rectangles](../Examples/Rectangles/Rectangles.swift) is the smallest plugin you can see on the
canvas: a kind, how it draws, and a tool that places it, with its key (R). These are all the steps it took, from
an empty directory to a tool in the app's toolbar. A plugin of your own takes the same ones.

**1. Write the module.** Every plugin is a Swift module with a directory of its own:
`Sources/<Name>`, or `Examples/<Name>` for an example. This is the whole of
`Examples/Rectangles/Rectangles.swift`:

```swift
import AppKit
import Canvas
import Keyboard

public struct Rectangle: BoxShapeProps {
    public static let kind: ShapeKind = "rectangle"
    public static let properties = Properties<Rectangle>(title: "Rectangle") {
        Property("frame", \.frame).required()
    }
    public var frame: CGRect
    public init(frame: CGRect) { self.frame = frame }
    public init() { self.init(frame: .zero) }
}

struct RectangleDefinition {}

extension RectangleDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Rectangle>, in context: RenderContext) {
        context.fillWithShadow(CGPath(rect: shape.frame, transform: nil), .systemTeal)
    }
}

public struct RectanglesPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "rectangles" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.shape(RectangleDefinition()) { rectangle in
            let place = rectangle.placement(size: CGSize(width: 160, height: 100)) { Rectangle() }
            rectangle.tool(label: "Rectangle", systemImage: "rectangle", shortcut: "r", placing: place)
        }
    }
}
```

`Rectangle` is the kind: its data, named once, with its list of properties (how a board writes it,
and what its JSON Schema says: [Properties](#properties)) and an `init()` that sets every member to
its default. `RectangleDefinition` says how it looks, and a kind with a frame needs to say nothing
else. `RectanglesPlugin` registers both, with a tool that puts a
160 × 100 rectangle where the canvas is pressed, and R, the key that switches to it: `shortcut:` is
the Keyboard horizontal's, which every key is registered with ([Keyboard
shortcuts](#keyboard-shortcuts)). [A vertical plugin](#a-vertical-plugin) goes through it part by
part.

**2. Declare it in `Package.swift`**, on one line, with its layer. Rectangles is a vertical (a
feature: a kind and its tool), and the modules of this project it imports are the core and
Keyboard, for its key:

```swift
.target(name: "Rectangles", dependencies: ["Canvas", "Keyboard"], path: "Examples/Rectangles"), // layer: vertical
```

`path:` is only for a module outside `Sources`. The dependencies must be exactly the modules the
code imports, apart from Apple's. `./build.sh audit` checks that in about a second, without
compiling, and says what's wrong in a line:

```
Examples/Rectangles/Rectangles.swift:3: Rectangles imports Geometry, but Package.swift doesn't list it as a dependency of Rectangles
Rectangles lists Geometry in Package.swift but never imports it
build.sh: Rectangles (vertical) may not depend on Ellipses (vertical); vertical may use: foundation horizontal
build.sh: Examples/Stars isn't a target in Package.swift
```

Every `./build.sh` and `./test.sh` runs it first. [The module graph](#the-module-graph) lists
everything it checks.

**3. Test it.** A module's tests are an executable, `Tests/<Name>Tests`, with its own line in
`Package.swift`:

```swift
.executableTarget(name: "RectanglesTests", dependencies: ["Canvas", "CanvasTesting", "Keyboard", "Rectangles", "TestKit"], path: "Tests/RectanglesTests"), // layer: test
```

Its `main.swift` runs its suites:

```swift
import TestKit

runTests([rectanglesTests])
```

and the tests drive a headless editor as a user would
([RectanglesTests.swift](../Tests/RectanglesTests/RectanglesTests.swift)):

```swift
@MainActor let rectanglesTests = Suite("Rectangles", [
    test("R and a press place a 160 × 100 rectangle that follows the pointer") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), RectanglesPlugin()])
        expect(h.key("r"))
        h.press(at: CGPoint(x: 300, y: 200))
        h.drag(to: CGPoint(x: 310, y: 205))
        h.release()
        let rectangle = try require(h.editor.document.shapes.first)
        expectEqual(rectangle.kind, Rectangle.kind)
        expectEqual(rectangle.box, CGRect(x: 230, y: 155, width: 160, height: 100))
        expectEqual(h.editor.currentToolID, .hand)
    },
])
```

A test may use only its module, what that module depends on, and the test kits (`CanvasTesting`,
`TestKit`). So this editor has Keyboard, which R needs, and no Selection: its default tool, which
placing returns to, is the Hand. A plugin that depends on Selection installs `KeyboardPlugin()` and
`SelectionPlugin()` first in its tests, as the app does. Run them with:

```
TEST_FILTER=Rectangles ./test.sh
```

`./test.sh` builds every module and runs every test executable. It also fails on a `Suite` that
`main.swift` doesn't pass to `runTests`, which would otherwise never run without a word. [Testing
plugins](#testing-plugins) has the rest of the kit.

**4. Ship it.** Three edits put it in the app:

- `Package.swift`: add it to Composition's dependencies.
- [`ShippedPlugins.swift`](../Sources/Composition/ShippedPlugins.swift): import it, and add
  `RectanglesPlugin()` to the list in `ShippedPlugins.plugins(pasteboard:model:)`. The list's order
  is the toolbar's, and the order overlays draw in.
- [`ShippedTests.swift`](../Tests/CompositionTests/ShippedTests.swift) pins the toolbar and
  [the registry report](#the-registry): add the new tool, `"Rectangle (R)"`, and the plugin's line,
  `rectangles          shape rectangle · tool rectangle · shortcut R → tool rectangle`.

Then `./build.sh && open build/InfiniteCanvas.app`, and press R.

A plugin list that doesn't register stops the app at launch, and CompositionTests fails before
that. The error says who clashed over what; the usual one is a key some other plugin has:

```
rectangles and stars both claim shortcut R in KeyboardShortcuts
```

[The registry](#the-registry) lists every error.

## I want to…

Once one plugin works, the question is which piece the next feature needs.

| I want to… | Use | Example |
|---|---|---|
| Add a shape with a frame | `BoxShapeProps`; a `ShapeDefinition` with `render`; a place tool | [Rectangles](#your-first-plugin) |
| Define a kind's properties: how boards write it, and its JSON Schema | `static let properties = Properties<K> { Property("text", \.text) }`, and `init()`; `registry.schema(for:)` | [Properties](#a-kinds-own-properties) |
| Bound a property (a length, a range), so a shape outside the bounds gets a validation warning | A modifier: `Property("text", \.text).maxLength(200)`, or an added property's `keywords`; Validation checks every shape against its kind's schema | [Checking shapes](#checking-shapes-against-their-schemas) |
| Add a shape without a frame (a line, a path) | `ShapeProps`; `geometry`, `hitTest` (with its `hitMargin`) and `CustomTranslation`; a tool that inserts it | [Polylines](#a-shape-without-a-frame) |
| Work out a kind's geometry from other shapes (a connector) | Look them up through the `ShapeContext`: `shape(_:)`, `geometry(of:)`, `hitTest(_:shape:)` | [Arrows](../Sources/Arrows/Connectables.swift) |
| Hit or outline a shape more exactly than its frame | Override `geometry`, `hitTest` or `indicatorPath` | [Ellipses](../Sources/Ellipses/Ellipses.swift) |
| Edit a shape in place, as text | `Editable`, and an `editingPlacement` | [StickyNotes](../Sources/StickyNotes/StickyNotes.swift) |
| Add a tool that makes no shape | `registrar.tool`, a `Tool` and a `Session` | [Eraser](#tools-and-sessions) |
| Give a tool its key | `shortcut:` on the call that registers the tool (Keyboard's) | [Rectangles](#your-first-plugin) |
| Make a key do something, or give a menu's command its key | `registrar.shortcut(chord, "Title") { ... }`, `registrar.command(_:shortcuts:)` | [Keyboard shortcuts](#keyboard-shortcuts) |
| Give a shape handles to drag | Selection's `HandleProviding` | [Arrows](../Sources/Arrows/ArrowDefinition.swift) |
| Edit a kind's properties beside the canvas | `x.details { DetailSection(...) }` | [TaskCards](#the-full-showcase-taskcards) |
| Add items to a kind's right-click menu | `x.contextMenu { MenuItem(...) }` | [TaskCards](#contributing) |
| Add a right-click item to every shape, or every kind with a capability | `registrar.contextMenuForEveryShape(where:)` | [Reordering](#every-shape-reordering) |
| Say how a kind's shapes appear in the table of contents | `x.contentsRow { ContentsLabel(...) }` | [StickyNotes](#the-table-of-contents) |
| Show in a kind's row what other shapes say (the names of the shapes it mentions), kept up to date | `x.contentsRow(affected: { changes, context in ... }) { shape, context in ContentsLabel(...) }` | [Rows read from more than their shape](#rows-read-from-more-than-their-shape) |
| Give a kind a title: a `title` in its schema, a pill on the canvas, and its row's name | `x.title()`, which Titles keeps (1 to 80 characters); or `x.title { ... }`, derived | [Titles](#a-horizontal-plugin), [EllipseTitles](#a-horizontal-plugin) |
| Rename a shape in the detail panel's header | `x.details(header: { $x in TitleHeader($x) }) {}` | [StickyNotes](#renaming-in-the-header-titleheader) |
| Name a kind's rows in the table of contents from another plugin | `x.contentsTitle { ... }` | [Titles](#a-horizontal-plugin) |
| Add a concern any kind can opt into | An `ExtensionPoint`, sugar on `ShapeRegistrar`, and whatever reads the point | [Titles](#a-horizontal-plugin), [Validation](../Sources/Validation/Validation.swift) |
| Give the shapes of the kinds that opt in something to hold (a checklist) | A `ShapeProperty`, `registrar.declare`, and `optIn(to:)` from the concern's sugar | [Checklists](#added-properties) |
| Give that concern a tab on the kinds that opt in | A `DetailTab` at order 50, contributed from the same sugar | [Checklists](#a-horizontals-feature-tab-checklists) |
| Give that concern menu items on the kinds that opt in | A `MenuGroup` at order 50, and `contextMenu` from the same sugar | [Checklists](#a-feature-that-comes-with-menu-items-checklists) |
| Edit an added property in the panel, or from the menu | `details(of: P.self) { DetailSection ... }`, `contextMenu(of: P.self) { MenuItem ... }` | [Checklists](#a-horizontals-feature-tab-checklists) |
| Opt another plugin's kind into a concern | A bridge, which imports both; `registrar.optIn(Kind.self, to:)` for an added property | [EllipseTitles](#a-horizontal-plugin), [ValidationDetails](#a-tab-of-status-lines-from-a-bridge-validationdetails) |
| Keep state per editor: an engine, a cache, a timer | `registrar.service`, an `EditorService`; redo what's kept per shape for the shapes each commit's `ChangeSet` names | [Validation](../Sources/Validation/Validation.swift)'s `ValidationEngine`, [TableOfContents](../Sources/TableOfContents/ContentsState.swift)' `ContentsState` |
| Show something small on shapes, just outside them or on a corner (a pill, a tally, a lock), on kinds you define or not | An `Adornment` type; `x.adornment`, `registrar.adornment(_:on:)` or `registrar.adornmentForEveryShape(_:where:)`, returning an `AdornmentLabel` | [Adornments](#adornments), [Titles](#a-horizontal-plugin) |
| Let the user put a flag on a shape, and show it | An added property, a menu item that sets it, and an adornment whose label reads it | [Something the user turns on](#something-the-user-turns-on) |
| Draw above every shape something that isn't one shape's adornment (a status outline, hints) | `registrar.overlay`, a `CanvasOverlay`; `editor.paintOrder(in: context.visibleRect)` | [Validation](../Sources/Validation/Validation.swift), [Arrows](../Sources/Arrows/ArrowDefinition.swift)' binding hints |
| Act on shapes about to be deleted (delete what depends on them) | `registrar.willDelete` | [The document](#the-editor-the-document-and-drawing) |
| Create a kind with a double-click on empty canvas | `x.createOnDoubleClick(place)` | [StickyNotes](../Sources/StickyNotes/StickyNotes.swift) |
| Keep a kind from being selected | `x.unselectable()`, or `x.selectable { ... }` | [Selection](#selection) |
| Go to shapes, as following a link does (select them, bring them into view, ⌘[ returns), or only bring them into view | Selection's `editor.goTo(_:)`, `editor.reveal(_:)` | [Selection](#selection) |
| Keep a kind from being copied | `x.uncopyable()`, or `x.copyable { ... }` | [The clipboard](#the-clipboard) |
| Keep some shapes from changing (a lock), and say why when something tries | `registrar.readOnlyShapes { ... }`; `EditorService.didRefuseChanges` | [Locking](#locking) |
| Put a button on the canvas that a click does something with (a chip), or a drag starts something from (a port's dot) | Selection's `registrar.canvasButtons(at:click:)` or `canvasButtons(at:drag:)`, drawn in an overlay with `editor.hoveredButton` and `editor.pressedButton`; or make an adornment a `ClickableAdornment` | [Canvas buttons](#canvas-buttons), [Locking](#locking), [Ports](#ports) |
| Make what you draw for a shape outside it count as the shape (a press, a hover, a right-click) | Selection's `registrar.decorationHits`; adornments already do | [DecorationHits](#drawn-for-a-shape-decorationhits) |
| Make part of a shape's content answer a click without taking the shape's press (a mention's pill, a link, a checkbox) | Selection's `registrar.shapeFaces(at:click:doubleClick:hovering:)` | [Faces](#faces-clickable-parts-of-a-shape) |
| Connect shapes with arrows: dots beside a kind's sides, dragged to another shape | `x.ports(C.self, sides:role:)`, on a channel; ArrowPorts draws the arrow | [Ports](#a-kinds-ports), [ArrowPorts](#the-connector-arrowports) |
| Declare a channel: a kind of connection, and which kinds take it | A `Channel` type, `registrar.channel(C.self)`; `ports` on each kind that takes it | [Channels](#channels) |
| Say what an arrow's end may bind to (tldraw's canBind) | Arrows' `registrar.arrowBindingRule { query in ... }` | [ArrowPorts](#the-connector-arrowports) |
| Let agents (or scripts) do something to a board from outside the app | `registrar.automationCommand("name", "…", params: P.self) { params, context in … }`: a `canvas` command | [The command line](#the-command-line) |
| Make a shape without the pointer: what a kind's tool places, or a shape from its JSON | `registry.placement(for:)`, `placement.shape(at:)`; `registry.shape(_:properties:)` | [The command line](#the-command-line) |
| Draw a shape away from where it is, for an animation (a shake) | `editor.setDrawingOffset(_:for:)`; adornments follow by themselves, and an overlay with `context.worldDrawingOffset(of:)` | [Locking](#locking) |
| Ask Claude something (and test it without the network) | `editor.languageModel?.respond(to: ModelRequest(...))`; `ScriptedLanguageModel` in tests | [Language models](#language-models) |
| Keep what a kind's props are bound to right as shapes are deleted and copied (a connector) | `ShapeReferencing` | [Arrows](../Sources/Arrows/ArrowDefinition.swift) |
| Let a kind's shapes be mentioned in text, as pills | `x.mentionable(untitled:symbol:…)` (Mentions) | [Mentions](#mentionable-kinds) |
| Let a kind's text mention shapes, drawn with pills and edited with a picker | A `MentionText` property; `x.mentionText { … }` and `context.drawMentionText`; a `MentionTextView` editor | [Mentions](#mention-text-and-its-stored-form) |
| Restrict what a text may mention to some kinds | `ScopedMentionText<Only<Kind>>`, or a declared scope: `registrar.mentionScope(S.self)` and `x.mentionable(in: S.self)` | [Scopes](#scopes-what-a-text-may-mention) |
| Hold names of shapes that may outlive them (a mention), renamed when copied with them | A value that adopts `ShapeNaming`; `registry.namingKinds` and `record.forEachNamingValue(in:)` to read them | [Values that name shapes](#values-that-name-shapes) |
| Put an editing view's selection where the press that began editing was | `editor.beginEditing(id, at: point)`, read as `EditContext.startPoint` | [Capabilities](#capabilities) |
| Name an undo step, or make several changes one | `editor.transact("Name") { ... }`; `editor.undoHistory.group("Name") { ... }`; `transact(coalescing:)` for a run of writes | [Undo](#undo) |
| Put a service's state back with undo (a selection) | `UndoParticipant` | [Undo](#undo) |
| Keep something about any shape beside its props (where it came from) | A `ShapeMetaKey`, and `record.meta[Key.self]` | [Metadata](#metadata) |
| Add a right-click item that isn't one shape's, in every menu and on empty canvas | `registrar.contextMenuForCanvas { ... }` | [The clipboard](#the-clipboard) |
| Show a shape's state in the panel: at its foot, or in a tab that shows while there's something to say | `registrar.detailStatusForEveryShape`, with `in: SomeTab.self` for a tab | [ValidationDetails](#a-tab-of-status-lines-from-a-bridge-validationdetails) |
| Show a shape's state at a glance in the table of contents: a dot on its row | `registrar.contentsMarkForEveryShape` | [ValidationContents](#marks-validationcontents) |
| Change a shipped kind's props | A migration in its `static let migrations`, and a fixture for the new version | [Boards on disk](#boards-on-disk) |
| Move a kind's own member onto an added property | `PropsMigration.handOver("checklist", to: ChecklistProperty.self)` in the kind's migrations | [StickyNotes](#boards-on-disk) |
| Change how an added property's value encodes | A `PropertyMigration` in the property's `migrations`, and a fixture in `Fixtures/added` | [Boards on disk](#boards-on-disk) |

The rule of thumb: behavior intrinsic to a kind is a [capability](#capabilities), a protocol its
definition adopts; behavior any plugin can add to any kind is an extension point.

## Horizontal and vertical

A **vertical** plugin is a feature: a shape kind and the tool that places it, or a tool on its own.
Sticky notes, ellipses, arrows, task cards, schema cards, rectangles, polylines and the eraser are
verticals.

A **horizontal** plugin is a concern that cuts across kinds. It declares an extension point, and any
kind can take part by contributing to it. Validity is the canonical example: *a shape can be valid
or invalid* is horizontal; *an empty sticky note is invalid* is one vertical opting in. Titles are
another. The horizontal owns the contract, the engine, and whatever it draws. Shapes never know
they're invalid; the validation plugin outlines them.

A horizontal can also be a feature that individual shapes opt into, and that shows up in the
[detail panel](#the-detail-panel) as a tab of its own, and in the [context menu](#context-menus).
Checklists is the example: one line, `note.checklist()`, gives every sticky note a checklist, a
property Checklists adds to the kinds that opt in ([added properties](#added-properties)), with a
Checklist tab in the panel, its bulk actions in the context menu, and a done/total chip on the
canvas (an [adornment](#adornments)). Checklists owns the property, the item type and everything
done with them; the kind declares nothing. One horizontal may build on another: Checklists imports
Adornments, DetailPanel and ContextMenus.

Selecting is a horizontal too, one that every kind is in unless it opts out
(`backdrop.unselectable()`). [Selection](#selection) owns what's selected and the way back
through it, the Select tool, and Delete, Return, ⌘A and Back; the detail panel builds on it to
show the selected shape. So are the keys: [Keyboard](#keyboard-shortcuts) holds every shortcut,
and a plugin whose tool or command has a key registers it there. So is [locking](#locking): any
shape can be locked, and Locking owns the lock, its chip (an adornment) and its shake, while the
core only refuses to change the shapes a plugin says are read-only. So are [ports](#ports): any
kind can have them, on the channels it takes, and Ports owns the dots and what a drag from one may
end on, while the plugin that owns a channel's meaning declares it. So is what's shown on shapes:
[Adornments](#adornments) lays out and draws what any plugin puts on them, a title's pill beside a
lock, so none overlaps another. So are [mentions](#mentions): any kind can be mentioned, and any
kind's text can hold mentions, while Mentions owns the stored form, the pills, the picker and what
keeps them in step with the shapes they name. And a horizontal may declare no point at all and only lend
something: [LanguageModels](#language-models) lends every editor the model plugins ask.

Opting in goes in one of two directions:

- **The vertical imports the horizontal** and contributes from inside its own `register`.
  StickyNotes does this for Validation: `note.validate { ... }`.
- **A bridge imports both**, and neither knows the other. `EllipseTitles` gives ellipses a title,
  though Ellipses has never heard of titles and Titles has never heard of ellipses. A bridge may
  join two horizontals: `ValidationDetails` shows each shape's validation issues in an Issues tab
  of the detail panel, and `ValidationContents` marks their rows in the table of contents, though
  Validation has never heard of either, nor either of validity. `ArrowPorts` makes arrows what a
  drag from a port draws, though Arrows has never heard of a channel, nor Ports of an arrow.

Either way the edge is visible in `Package.swift`, and the dependency always points from the
vertical (or bridge) to the horizontal, never back.

## The module graph

Every plugin is its own Swift module, and `Package.swift` is the single place the dependencies
between them are written. `build.sh` reads it, refuses to build anything it doesn't match, and
compiles each module on its own, with only its dependency closure on the include path.

```
./build.sh graph      each module's layer, what it depends on, and what depends on it
./build.sh dot        the same, for Graphviz (./build.sh dot | dot -Tsvg > graph.svg)
./build.sh audit      check everything below without compiling
./build.sh api Canvas a module's public interface: its contract (public is the barrel)
```

Each target is one line, with its layer:

```swift
.target(name: "StickyNotes", dependencies: ["Canvas", "Checklists", "DetailPanel", "Keyboard", "Selection", "TableOfContents", "Titles", "Validation"]), // layer: vertical
.target(name: "EllipseTitles", dependencies: ["Canvas", "Ellipses", "Titles"], path: "Examples/EllipseTitles"), // layer: bridge
```

| Layer | May depend on | Modules |
|---|---|---|
| wire | wire | CanvasRPC (what the app and its [command line](#the-command-line) say to each other) |
| foundation | foundation | Geometry, Canvas (the core) |
| ui | foundation, wire | CanvasUI (the AppKit view, the SwiftUI toolbar, `CanvasFocus`, and the command line's server) |
| horizontal | foundation, horizontal, wire | Keyboard, Selection, Validation, Titles, DetailPanel, ContextMenus, TableOfContents, Adornments, Checklists, Clipboard, Locking, Ports, Mentions, Automation, LanguageModels |
| vertical | foundation, horizontal | Arrows, StickyNotes, Ellipses, TaskCards, Schemas, Rectangles, Polylines, Eraser, Reordering |
| bridge | foundation, horizontal, vertical | EllipseTitles, ValidationDetails, ValidationContents, ArrowPorts |
| composition | foundation, horizontal, vertical, bridge, wire | Composition (the shipped plugin list) |
| app | foundation, ui, composition, wire | InfiniteCanvas |
| cli | wire | CanvasCLI (`canvas`, an executable: it knows the wire, never the app) |
| testsupport, test | (see Package.swift) | TestKit, CanvasTesting, `*Tests` |

What `./build.sh audit` enforces:

- **No cycles.** The graph is sorted topologically; a cycle is printed as a path.
- **Layers.** A horizontal can't import a vertical, a vertical can't import another vertical, the
  app reaches plugins only through Composition, and nothing but the app and tests sees CanvasUI.
- **Imports match the manifest, both ways.** The compiler lists each module's imports. An import
  that isn't a declared dependency fails, and so does a declared dependency that's never imported.
  `@_exported`, `@_implementationOnly` and `@testable` are banned, since each hides an edge, and
  so are imports inside `#if`.
- **No other module's ids as literals.** A module that writes another module's kind, plugin, tool,
  added property or channel id as a string literal (`kind == "sticky-note"`) without depending on
  it fails. An id is a module's when it declares it as a static `ShapeKind`, `ToolID`, `PluginID`,
  `PropertyKey` or `ChannelID` (`static let id: ChannelID = "note-link"`), or as its plugin's
  `id`. A kind's own property names (`Property("title", ...)`) are only that kind's, so they're
  exempt, and so is a JSON member named by one of JSON Schema's keywords, which schemas write
  wherever they're built or read, and which ordinary words, and so ids, may also be (Titles'
  `title` property): a subscript's key (`json["title"]`) or a key before a colon where a member's
  name can start (`["title": ...]`, after a comma, or starting a line of JSON text), but not in a
  `case`'s patterns or its `where`, on its line or the lines they go on to, nor in a ternary
  (`? "title" : …`, even across a line), nor after an operator (`prefix + "title" : …`). Any other
  member's name counts: reading another plugin's property out of a shape's JSON
  (`json["locked"]`) needs the dependency. Lookups at run time (a tool by its shortcut or label)
  aren't audited.
- **The host API is fenced off.** What `CanvasView` calls on the editor (input, the cursor,
  drawing, the delegate) is `@_spi(Host)`. Only modules that `@_spi(Host) import Canvas` see it,
  and only the ui, testsupport and test layers may; a plugin that calls it doesn't compile.
- **No shadowing names.** A public type named like a module fails, and so does a public `Task`,
  which would shadow Swift's `Task` in every module that imports it.
- **Package.swift is real SwiftPM.** The audit evaluates it with SwiftPM's own `PackageDescription`
  and fails if SwiftPM would see a different graph, so Xcode opens the same project.

On top of that, the compiler sees only a module's dependency closure (`-I`), so nothing outside
it can be named at all, and every module compiles with `MemberImportVisibility`, so using a member
from a module you didn't import is an error rather than a silent transitive edge. (Importing a
transitive dependency without declaring it is what the import check above catches.)

**Adding a module** is [Your first plugin](#your-first-plugin), steps 2 to 4. Every non-app module
is compiled by `./test.sh`, even before anything depends on it.

## A vertical plugin

[Rectangles](#your-first-plugin) is a whole vertical. What each part of it does:

- **The kind is its props.** `ShapeProps` values are `Equatable` and `Sendable`, and list their
  properties (`SchemaDefined`): the list makes them `Codable` and gives them a JSON Schema
  ([Properties](#properties)). `BoxShapeProps` adds a `frame`, and with it most behavior for free.
  The document stores each shape as an `AnyShapeRecord` (id, kind, props, and the values of any
  [added properties](#added-properties)). Definitions get it typed, as `ShapeRecord<Rectangle>`.
- **The definition is stateless.** For a box kind, only `render` is required. The rest has defaults:

  | Requirement | Default |
  |---|---|
  | `geometry(of:in:)` | the frame (box kinds); every other kind must say ([a shape without a frame](#a-shape-without-a-frame)) |
  | `hitTest(_:on:in:)` | inside the geometry's closed outline |
  | `hitMargin` | none: how far past its geometry's bounds `hitTest` can still say yes |
  | `indicatorPath(of:in:)` | the geometry's outline (the target hint, and hover and selection outlines) |

  `geometry` is the one source of truth. Override it and hit testing, the outline, the marquee,
  arrows and the minimap (which draws each shape as a silhouette of its outline) all follow.
  Override `hitTest` or `indicatorPath` only when you can do better; Ellipses does both (an
  exact hit test, a smooth outline). A `hitTest` that reaches past the outline (a
  stroke, a few points of slop) says how far in `hitMargin`: the editor asks it only about points
  that near. A kind that knows better than its geometry whether the marquee touches it (Arrows,
  against its arc) adopts Selection's `BrushHitTesting`.
- **Other shapes come through the context.** The editor keeps each shape's geometry from frame to
  frame, until the shape changes or a shape its definition looked up while working it out does. So
  a definition that looks at other shapes (Arrows, at the shapes they join) does it through its
  `ShapeContext`: `shape(_:)`, `geometry(of:)` and `hitTest(_:shape:)` keep track. Reading all of
  `context.document`, or `context.camera`, while working out a geometry ties it to every change of
  them.
- **Conform in an extension**, as Rectangles does, for `ShapeDefinition` and its capabilities,
  `Tool`, `Session`, `EditorService`, and an extension point that implements `check`. Swift flags a
  member that *nearly* matches a defaulted requirement (a wrong label, a missing return type) only
  in the extension that declares the conformance, and the build fails on it. Declared on the type,
  a near miss compiles and the default silently runs.
- **The kind is stated once.** Everything registered inside `registrar.shape(...) { rectangle in ... }`
  is stamped with `"rectangle"`: the tool's id, its report line, and any horizontal contributions.
- **Placements create box shapes** for place tools and Selection's double-click claim.
  `placement(size:props:)` centers a new shape on the press, brings back the default tool (Select,
  which selects the new shape), and lets it follow the pointer until release. `editingPlacement`
  opens it for editing instead, and exists only for `Editable` kinds, a restriction the compiler
  checks. Any tool can also insert a shape itself, with `editor.transact { $0.insert(record) }`, as
  the arrow tool does.

What a real vertical adds on top ([StickyNotes](../Sources/StickyNotes/StickyNotes.swift)):

```swift
registrar.shape(StickyNoteDefinition()) { note in
    let place = note.editingPlacement(size: NoteStyle.size) { StickyNote() }
    note.tool(label: "Note", systemImage: "note.text", shortcut: "n", placing: place)   // and N, with Keyboard
    note.createOnDoubleClick(place)          // opts into Selection: double-clicking empty canvas places a note
    note.validate { shape, _ in              // opts into the Validation horizontal
        shape.isEmpty ? [.warning("This note is empty.")] : []          // no text, checklist or title
    }
    note.checklist()                         // opts into Checklists: a checklist on every note, a panel tab and a chip
    note.title()                             // opts into Titles: a title Titles keeps, its pill, and its row's name
    note.details(header: { $note in TitleHeader($note) }) {}      // renamed in the panel's header
}
```

The note's render draws its text with string drawing (`NSAttributedString.draw`), and its editing
view is a TextKit 2 `NSTextView` laid over it, which the canvas scales by the zoom; the two must
put the text on the same lines, or it moves when editing starts. Both take
`NoteStyle.textAttributes`, whose paragraph fixes every line at 19 points (`NoteStyle.lineHeight`):
string drawing's own pitch for the font, so the render is as it was, where TextKit 2 would set the
lines 18 points apart. At the same height TextKit 2 sets a line's glyphs a point lower in it, so the
editor's text starts a point higher, 15 points down (`NoteStyle.editorInset`), and its lines fall
on the render's, pixel for pixel but anti-aliasing, as typed text does too (StickyNotesTests).

## Tools and sessions

A **tool** handles what happens before a press: hover, the press itself, and which cursor to
show. It's a class with one instance per editor, so it can keep state. A **session** owns one
press-drag-release. It lives on the editor, not the tool, so it outlives tool switches. A place tool
switches back to the default tool and keeps dragging its new shape; the arrow tool drags first and
switches after.

[`Examples/Eraser`](../Examples/Eraser/Eraser.swift) is a tool with no shape:

```swift
import Canvas
import CoreGraphics
import Keyboard

extension ToolID {
    public static let eraser: ToolID = "eraser"
}

public struct EraserPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "eraser" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.tool(ToolDescriptor(id: .eraser, label: "Eraser", systemImage: "eraser"), shortcut: "e") { _ in EraserTool() }
    }
}

final class EraserTool {}

extension EraserTool: Tool {
    func pointerDown(_ pointer: Pointer, in editor: CanvasEditor) {
        let session = ErasingSession()
        editor.session = session
        session.drag(pointer, in: editor)
    }
}

@MainActor
final class ErasingSession {
    private var last: CGPoint?
}

extension ErasingSession: Session {
    /// Tests the whole path since the last event, so a quick stroke doesn't skip a thin shape.
    func drag(_ pointer: Pointer, in editor: CanvasEditor) {
        let from = last ?? pointer.world, to = pointer.world
        last = to
        let step = 2 / editor.shapeContext.zoom               // every 2 view points
        let count = max(1, Int((hypot(to.x - from.x, to.y - from.y) / step).rounded(.up)))
        var hits: Set<ShapeID> = []
        for i in 0...count {
            let t = CGFloat(i) / CGFloat(count)
            if let id = editor.shape(at: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)) {
                hits.insert(id)
            }
        }
        guard !hits.isEmpty else { return }
        editor.transact { $0.delete(hits) }
    }
}
```

When the eraser deletes a shape an arrow is bound to, the arrow lets go of it by itself: arrows
adopt `ShapeReferencing`, which the core asks as it deletes a shape. The eraser never heard of
arrows.

The details:

- **`Tool`**: `pointerDown` (may start a session), `pointerMoved` (hover, with no session
  running), `pointerExited`, `modifiersChanged`, `cursor(in:)`, `cancel` (Escape; return true if
  you handled it). All but `pointerDown` have defaults.
  `ignoresPress` (default false) is asked first of every press: true lets it pass as though it
  never came, so the camera goes on moving, editing goes on, `pointerDown` isn't called and no
  session starts (its drags do nothing, and its release only hovers). It's for the rest of a click
  the tool has already acted on: the select tool ignores the second press of a double-click whose
  first click, on a [face](#faces-clickable-parts-of-a-shape), went to a shape.
- **`Session`**: `drag`, `end`, `cancel` (Escape; return true if you cancelled), `modifiersChanged`,
  `cursor(in:)`, `hidesOutlines` (plugins' outlines aren't drawn while it runs, for a drag that
  reshapes a shape its outline would crowd, like an arrow's handle), `draw(in:)` (what it shows
  while it runs, like a marquee, above the world overlays). A session can hand over to another by
  setting `editor.session` (pressing an arrow handle becomes dragging it). A session that sets
  `editor.hintedShapeID` clears it when it ends.
- **The default tool** is where the editor starts, and where Escape and placing a shape return. One
  plugin may claim it (`registrar.defaultTool(.select)`, as Selection does); without a claim it's
  the Hand. Claiming a tool nobody registers is `RegistryError.invalid`.
- **Escape** (Keyboard's key for `editor.cancel()`) goes to the running session (`cancel`), else to
  the tool (`cancel`), else back to the default tool. Escape while shapes move with the pointer
  (`TranslatingSession`) puts every one back where it was when the drag began (tldraw's behavior):
  a lone box, a selection, an arrow (its precise ends included) or a shape just placed.
- **Input**: tools see `Pointer` values, never `NSEvent`s. A `Pointer` has `view` (view points)
  and `world` (world units) locations, `modifiers` and `clickCount`. `editor.pointerSpeed` is
  smoothed like tldraw's. `editor.effectiveModifiers` counts a key released in the last 150 ms as
  still held, so letting go of ⌥ and the mouse together doesn't undo ⌥.
- **Time**: timers go through `editor.scheduler`. Tests swap in a `ManualScheduler` and run time by
  hand, which is how the arrows' 600/320/150 ms timers are pinned to the millisecond, and how the
  hand tool's slide plays frame by frame.
- **Keys** are [Keyboard's](#keyboard-shortcuts): a tool's is `shortcut:` on the call that registers
  it (the eraser's E, above). A tool id used twice is a registry error, and so is a key.
- **The toolbar** is the default tool, then the rest in plugin-list order, the core's Hand first. It
  follows `editor.currentToolID`, which is observable.
- **Redrawing**: the core redraws whenever the document, camera, tool or session changes. A plugin
  whose drawn state changes some other way (its own state, a timer) calls `editor.setNeedsDisplay()`,
  as Selection does when the selection or hover changes; a tool whose cursor follows such state
  calls `editor.refreshCursor()`.
- **Commands** (`CanvasCommand`: `.delete`, `.selectAll`, `.goBack`, `.cut`, `.copy`, `.paste`)
  are what menu items run: the canvas view forwards Edit › Delete and Edit › Select All (AppKit's
  standard actions) with `editor.perform`, the board's window Go › Back (⌘[) whatever has the
  keyboard, and Edit › Cut, Copy and Paste wherever text doesn't take them first, and a key or any
  plugin may run one. A plugin claims each with `registrar.command`, or with Keyboard's
  `registrar.command(_:shortcuts:)`, which gives it its keys too, and may say when it can run
  (`isEnabled:`), which `editor.canPerform` asks for a menu item to enable it, and a key to take
  the stroke; unclaimed, or unable to run, `perform` returns false.
- **The secondary click** (a right-click, or a Control-click) opens whatever menu the one plugin
  that claims it makes (`registrar.menuForSecondaryClick`), ContextMenus in the shipped app;
  unclaimed, or nil, the click does nothing. AppKit offers a Control-click to the menu first; with
  none, it reaches the tool as a press with `pointer.isControlClick` set (exact, unlike `modifiers`,
  which count ⌃ let go in the last 150 ms). The select tool ignores it, since it's the secondary
  click there; a tool that reads ⌃ as a modifier (the arrow tool binds nothing) takes the press.
  See [context menus](#context-menus).

## A shape without a frame

A kind with a frame gets three things from it: where the shape is, what hits it, and how it moves.
A kind without one (a line, a path, a connector) says each itself.
[`Examples/Polylines`](../Examples/Polylines/Polylines.swift) is a freehand line: the points the
pointer passes through while it's dragged with the Line tool (L).

```swift
public struct Polyline: ShapeProps {
    public static let kind: ShapeKind = "polyline"
    public static let properties = Properties<Polyline>(title: "Line") {
        Property("points", \.points).description("In world units, in the order they were drawn.")
    }
    public var points: [CGPoint]
    public init(points: [CGPoint]) { self.points = points }
    public init() { self.init(points: []) }
}

extension PolylineDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Polyline>, in context: RenderContext) {
        let cg = context.cg
        cg.addLines(between: shape.props.points)
        cg.setStrokeColor(PolylineStyle.color.cgColor)
        cg.setLineWidth(PolylineStyle.strokeWidth)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.strokePath()
    }

    /// Required: only box kinds have a default. Open, so nothing is inside it.
    func geometry(of shape: ShapeRecord<Polyline>, in context: ShapeContext) -> ShapeGeometry {
        ShapeGeometry(outline: shape.props.points, isClosed: false)
    }

    /// The default hits only inside a closed outline, so an open kind says what hits it: here,
    /// anything within a few view points of the stroke.
    func hitTest(_ point: CGPoint, on shape: ShapeRecord<Polyline>, in context: ShapeContext) -> Bool {
        let margin = PolylineStyle.hitMargin / context.zoom + PolylineStyle.strokeWidth / 2
        let points = shape.props.points
        return zip(points, points.dropFirst()).contains { distanceToSegment(from: point, $0, $1) <= margin }
    }

    /// `hitTest`'s margin, past the points: the editor asks `hitTest` only about points this near.
    var hitMargin: HitMargin { HitMargin(world: PolylineStyle.strokeWidth / 2, view: PolylineStyle.hitMargin) }
}

extension PolylineDefinition: CustomTranslation {
    func beginTranslation(of shape: ShapeRecord<Polyline>, movingWith _: Set<ShapeID>,
                          in _: inout Transaction) -> ShapeTranslation<Polyline> {
        let start = shape.props.points
        return ShapeTranslation { delta, shape, _ in
            shape.props.points = start.map { $0 + delta }
        }
    }
}
```

- **`ShapeProps`, not `BoxShapeProps`.** Nothing that works from a frame applies: no default
  geometry, no placements, and no Arrange tab in the detail panel. The core culls it by its
  geometry, as it culls a box by its frame.
- **`render` draws in world units**, into `context.cg`, with the camera already applied and a fresh
  graphics state each time; AppKit drawing (`NSAttributedString.draw`) lands there too.
  `context.zoom` turns view points into world units, `context.isEditing` says the shape's editing
  view is up, and `fillWithShadow` fills a path the way the canvas's other shapes are filled.
- **`geometry` is required**, and the rest of the canvas reads it. Hover and selection stroke the
  outline, left open. The marquee selects a line when it crosses one of its segments: for an open
  outline, Selection's default `isHit(byBrush:)` never considers an inside. And `isClosed: false`
  keeps arrows off it, since they bind only to closed shapes.
- **`hitTest` is required in practice.** The default hits only inside a closed outline, so an open
  kind that doesn't say can't be pressed, hovered or erased. Hit margins are view points, divided
  by `zoom`. `hitMargin` says how far past the points they reach (in world units, for the stroke,
  plus view points): the editor asks `hitTest` only about points within the geometry's bounds
  grown by it, so a point in a margin left out would miss.
- **`CustomTranslation` moves it.** The core moves a shape with a frame by its frame; any other kind
  stays put when the selection is dragged, unless it moves itself. `beginTranslation` runs once, as
  the drag starts: capture what you move from. The closure it returns runs on every drag event,
  with the pointer's offset from the press. Escape puts the shape back without your help: its
  whole record as it was before `beginTranslation` (a box kind moved by its frame gets its origin
  back, and keeps anything else written to it while it moved).

**The tool inserts the shape itself.** Placements make box shapes, so the Line tool starts a
session, which puts the line in on the first drag (a click draws nothing, as with arrows) and adds
a point on every drag after that:

```swift
extension DrawingSession: Session {
    func drag(_ pointer: Pointer, in editor: CanvasEditor) {
        if let id {
            editor.transact { $0.update(id, as: Polyline.self) { $0.props.points.append(pointer.world) } }
        } else {
            let line = ShapeRecord(Polyline(points: [start, pointer.world]))
            editor.transact { $0.insert(line) }
            id = line.id
        }
    }

    /// Escape takes back the line being drawn.
    func cancel(in editor: CanvasEditor) -> Bool {
        if let id { editor.transact { $0.delete([id]) } }
        return true
    }
}
```

The tool stays current after a line, as the eraser does. Its id is the kind's,
`ToolID(placing: Polyline.kind)`, as a place tool's is, so the detail panel names a selected line
after the tool: "Line", with the tool's symbol.

[Arrows](../Sources/Arrows/ArrowDefinition.swift) is the full-size version: a kind without a frame
that also has handles (`HandleProviding`), an exact marquee test (`BrushHitTesting`), a paint order
of its own (`PaintOrderAnchored`), and a translation that keeps its bindings. It lends other
plugins two things, and knows nothing of why ([ArrowConnecting.swift](../Sources/Arrows/ArrowConnecting.swift)):
rules for what an arrow's end may bind to (`ArrowBindingRules`, tldraw's canBind), and an arrow
drawn for a gesture of theirs (`editor.beginArrow`), which is how [ports](#the-connector-arrowports)
draw theirs.

## A horizontal plugin

A horizontal declares an extension point, gives other plugins a pleasant way to contribute, and
consumes what they contribute. [Titles](../Sources/Titles/Titles.swift) is a small one: what a
shape is called, a trait any kind can opt into.

```swift
extension PluginID {
    public static let titles: PluginID = "titles"
}

/// ① What a shape is called, where Titles keeps it: a property it adds to the kinds that opt in,
/// and so a property of their schemas, with its bounds.
public enum TitleProperty {}

extension TitleProperty: ShapeProperty {
    public static let key: PropertyKey = "title"
    public static var defaultValue: String? { nil }             // nil until the shape is named
    public static var keywords: PropertyKeywords<String> {
        PropertyKeywords().description("What the shape is called.").minLength(1).maxLength(maxLength)
    }
    public static let maxLength = 80
}

/// ② The extension point: declared and read by this plugin, filled by others. One title per kind.
public enum ShapeTitles {}

extension ShapeTitles: KeyedExtensionPoint {
    public typealias Contribution = TitleContribution       // a shape's title, and whether it shows a pill
    public static var owner: PluginID { .titles }
    public static func uniqueKeys(of _: TitleContribution, for target: ShapeTarget) -> [AnyHashable] { [target] }
}

/// ③ Sugar, so opting in is one line: `note.title()`.
extension ShapeRegistrar {
    public mutating func title(pill: Bool = true, contents: Bool = true) {
        optIn(to: TitleProperty.self)                                     // the property, in the kind's schema
        title(pill: pill, contents: contents) { $0[TitleProperty.self] }  // what the shape is called: its value
    }

    /// A title derived from what the kind keeps itself: `label.title { $0.props.text }`.
    public mutating func title(pill: Bool = true, contents: Bool = true,
                               _ make: @escaping @MainActor (ShapeRecord<Definition.Props>) -> String?) {
        contribute(TitleContribution(Definition.Props.self, showsPill: pill, make), to: ShapeTitles.self)
        if contents { contentsTitle { oneLine(make($0)) } }     // TableOfContents' point: the title names the shape's row
    }
}

extension PluginRegistrar {     // for a kind another plugin registers (bridges use these)
    public mutating func title<P: ShapeProps>(_: P.Type, pill: Bool = true, contents: Bool = true) { ... }
    public mutating func title<P: ShapeProps>(_: P.Type, pill: Bool = true, contents: Bool = true,
                                              _ make: @escaping @MainActor (ShapeRecord<P>) -> String?) { ... }
}

/// ④ The consumers: a lookup, and the pill, an adornment Titles places on every titled shape.
extension Registry {
    public func title(of shape: AnyShapeRecord) -> String? { ... }     // on one line; nil if there's none, or it's blank
}

public enum TitlePill {}
extension TitlePill: Adornment {
    public static var placement: AdornmentPlacement { .aboveTopLeft }   // the left end of the row above the shape
    public static var order: Int { 50 }                                // a horizontal's feature
}

public struct TitlesPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .titles }
    public func register(into registrar: inout PluginRegistrar) {
        registrar.declare(TitleProperty.self)
        // On every shape whose kind's title shows a pill (not `pill: false`): its title, or none.
        registrar.adornmentForEveryShape(TitlePill.self, where: { $0.registry.showsTitlePill($0.kind) }) { shape, context in
            context.registry.title(of: shape).map { AdornmentLabel($0) }
        }
    }
}
```

A title someone gives a shape is Titles' to keep: `note.title()` opts the kind into Titles' `title`
property, and each note holds its own, nil until someone names it. It's in the kind's schema, where
Titles says what a title is: a string of 1 to 80 characters. A blank one is no title at all
(`TitleProperty.isNone`), so no shape holds one: a note named "   ", or read from a board with an
empty title, is untitled. Nothing stops a longer one (a pasted paragraph):
[Validation](#checking-shapes-against-their-schemas) checks every shape against its kind's schema,
so the shape gets a warning, "Title is 95 characters long, and should be at most 80.", with the
title kept as it is. A kind that stores a title of its own would have none of that, so notes and
tasks hand theirs over ([Boards on disk](#boards-on-disk)).

A title may be derived instead, from what the kind keeps itself: then it isn't data, and isn't in
the schema. The bridge that opts ellipses in,
[`Examples/EllipseTitles`](../Examples/EllipseTitles/EllipseTitles.swift), derives one from the
ellipse's size, though Ellipses has never heard of titles:

```swift
registrar.title(Ellipse.self) { ellipse in "Ellipse, \(Int(ellipse.frame.width)) × \(Int(ellipse.frame.height))" }
```

Either way, a shape may have none: nil or blank is no title. However it's written, a title reads
on one line wherever it shows (each run of whitespace folds into a space), so the lookup, the pill
and the row agree. What a title brings:

- **A pill** at the left end of the row just above the shape (18 points tall, 9 above the top edge,
  clear of a checklist's tally on the corner): one line, as long as the title and no longer than
  the row leaves it, where a longer title ends in "…". The row is the shape's width, less what's
  at its right end (a [lock](#locking)) and 4 points before it, so locking a note with a long
  title shortens its pill by 22 points, until the lock has gone; with under 30 points left, there's
  no pill. The pill is `TitlePill`, an [adornment](#adornments): Titles places it on every shape
  whose kind's title shows one, though it defines no kind, and Adornments lays it out with
  whatever else the shape shows, so it never meets the lock or the tally. It keeps its size on
  screen, shrinking with the shapes below 25% zoom, goes where its shape is drawn (it shakes with a
  locked shape), and is its shape's for the pointer: a click on it selects the shape, a drag moves
  it, and a double-click edits a note. A kind that draws its title itself leaves it out:
  `task.title(pill: false)`.
- **Its row's name** in [the table of contents](#the-table-of-contents), through TableOfContents'
  `ContentsTitles`, which names a kind's rows without replacing them: a titled note is listed by
  its title, with its checklist's tally; an untitled one by its text, as before. `contents: false`
  leaves the kind's row as it is.
- **A rename in the detail panel**, for a kind that wants one: [`TitleHeader`](#renaming-in-the-header-titleheader),
  which the kind puts in its header.

So Titles builds on three horizontals, as Checklists does: it imports Adornments, TableOfContents
and DetailPanel, and a plugin list with a titled kind needs `TitlesPlugin`, `AdornmentsPlugin`
(with Keyboard and Selection, which it builds on) and `TableOfContentsPlugin` (without one,
`ownerNotInstalled` names it).

The mechanics:

- **The type is the key.** No strings, no slot files, no install step. Contributing to a point
  means importing the module that declares it, so the dependency is in `Package.swift`.
- **`owner`** is the plugin that declares and consumes the point. Contributing to a point whose
  owner isn't installed is `RegistryError.ownerNotInstalled` at startup, so installing StickyNotes
  without Validation fails loudly instead of silently dropping its rules. Plugins never list their
  dependencies a second time.
- **Targets.** A contribution is for one kind (`.kind(k)`, stamped for you inside `shape { }`) or
  for every kind (`.any`, the `"*"` wildcard). `contributions(to:for:)` returns the kind's own
  first, then the wildcards, each in plugin order. A contribution for a kind nobody registers is
  `RegistryError.unknownKind`.
- **List or keyed.** A plain `ExtensionPoint` collects a list: validation rules, overlays. A
  `KeyedExtensionPoint` says which keys each contribution claims. Two claims to the same key are
  `RegistryError.conflict`, so plugin order never picks a winner. `[target]` means one per kind.
  A rule that spans contributions in a way keys can't say goes in the point's `check`
  ([the registry](#the-registry) runs it).
- **One per kind.** A point keyed by `[target]` (a rule, as Selection's `ShapeSelectability` and
  Clipboard's `ShapeCopyability` are) takes one contribution per kind plus one for every kind;
  `registry.contributionByKind(to:)` is each kind's (its own, else every kind's), which a service
  keeps, since the registry never changes.
- **Engines are services.** A horizontal with state (a cache, an index) registers an
  `EditorService`, made per editor, with `registrar.service { ValidationEngine(editor: $0) }`, and
  anyone finds it with `editor.service(ValidationEngine.self)`. Validation's engine recomputes when
  `editor.revision` changes and is cached otherwise.
- **Something small shown on a shape is an [adornment](#adornments)**, laid out with the rest so
  none overlaps another, as Titles' pill is. Anything else a horizontal draws (an outline around
  the shape, as Validation's) is an overlay, `registrar.overlay`, above every shape. World overlays
  draw with the camera transform; view overlays draw in view points.
- **Data on the shape is an added property.** A concern that gives each shape something to hold
  (Checklists' items) declares a `ShapeProperty`, and its sugar opts the kind in
  ([Properties](#added-properties)). Its extension point then holds only how the kind takes part:
  `ShapeChecklists` says whether the canvas shows the chip.
- **Contracts should be pure.** Validation rules read the document only through
  `ValidationContext`, so dependency tracking can replace full recomputation later without
  changing any rule. Design your contexts the same way.

[Validation](../Sources/Validation/Validation.swift) is the full-size version of the same pattern:
per-kind rules, rules for another plugin's kind, rules for every kind, an engine, and an overlay.
Its model is ESLint's: a rule finds issues on a shape, each an error or a warning, two channels of
one thing (`.error("A task needs a title.")`, `.warning("This note is empty.")`). An error makes
the shape invalid; a warning only flags it. Validation has one rule of its own, for every kind:
each place a shape breaks its kind's schema is a warning, about the property it's in
([Checking shapes](#checking-shapes-against-their-schemas)). The overlay outlines a shape with issues in its worst
one's color, red for an error and orange for warnings alone, and a shape without issues not at
all. Two bridges show the issues elsewhere, though Validation has never heard of either place: the
detail panel lists a shape's issues in an Issues tab
([ValidationDetails](#a-tab-of-status-lines-from-a-bridge-validationdetails)), and the table of
contents puts a dot of the same color on the row of each shape with issues, so the board's are
found at a glance and a click goes to one ([ValidationContents](#marks-validationcontents)).

## Properties

A shape's data is its properties. Most are its kind's own, which the kind lists. Others are added
by a plugin to the kinds that opt in, as Checklists adds a checklist. Both are typed, saved with the
shape, versioned, and described by one JSON Schema per kind.

### A kind's own properties

A kind lists its properties beside `static let kind`, and has an `init()` that sets every member to
its default ([StickyNotes](../Sources/StickyNotes/StickyNotes.swift)):

```swift
public struct StickyNote: BoxShapeProps {
    public static let kind: ShapeKind = "sticky-note"
    public static let properties = Properties<StickyNote>(title: "Sticky note") {
        Property("frame", \.frame).required()
        Property("text", \.text).description("What the note says.")
    }
    public var frame: CGRect
    public var text: String
    public init(frame: CGRect = .zero, text: String = "") { ... }
    public init() { self.init(frame: .zero) }
}
```

(A note's title and checklist are properties too, the ones Titles and Checklists add to it:
[added properties](#added-properties).)

The list is the kind's `Codable` and its schema (`SchemaDefined`, which `ShapeProps` refines), so
the two never disagree:

- **Writing and reading.** A board writes each property under its name, and leaves out a nil
  optional. Reading takes each from its name. A member that's missing, or null, reads as its value
  in `init()`, unless it's `required()`: then the read fails, and a board keeps the shape aside.
- **Types come from the members.** Strings, booleans, integers, `Double` and `CGFloat`, `UUID`,
  `Date` (ISO 8601), arrays, sets (`uniqueItems`), and optionals, as what they wrap. `CGRect`,
  `CGPoint`, `CGSize` and `ShapeID` are the core's shared definitions (`core.rect`, `core.point`,
  `core.size`, `core.shape-id`); a rect is `[[x, y], [width, height]]`, as a board writes it.
- **Defaults come from `init()`.** Each property's `default` is its member's value there, except a
  nil optional's. `required()` means there's none: a board, or anyone writing one, must give it.
  Only those are `required` in the schema. Every shipped box kind's `frame` is one.
- **Modifiers** add JSON Schema keywords: `title`, `description`, `minimum`, `maximum`,
  `minLength`, `maxLength` (both in code points, as JSON Schema counts), `pattern`, `minItems`,
  `maxItems`, `examples`, `deprecated()`, `readOnly()`, and `keywords([...])` for any other
  (`.keywords(["multipleOf": 0.5])`). A task's estimate is
  `Property("estimate", \.estimate).minimum(0).description("Hours.")`. A bound says what a shape's
  value should be, not what it can be: nothing refuses a value outside it, and Validation warns
  about the shape ([Checking shapes](#checking-shapes-against-their-schemas)). The modifiers are
  `PropertyModifiers`, which an added property's `keywords` take too.
- **A string enum** adopts `SchemaCases` and titles its cases: its schema is `oneOf` a `const` per
  case, with its title. TaskCards' `TaskStatus` titles its cases with their labels ("To Do", "In
  Progress").
- **A struct in the props** is `SchemaDefined` too, with a list of its own (TaskCards' `TaskColor`
  and `TaskDisplay`, Arrows' `ArrowBinding`), written out where it's used. Given a name, it's a
  shared definition instead, which each use refers to: `Properties<ChecklistItem>(title: "Checklist
  item", definition: "item")` is `checklists.item` in a schema, named after the module that
  declares the type, so a type has one name wherever it's described, and two modules' definitions
  never collide. A struct that holds itself (a tree) needs a name, and its definition then refers to
  itself.
- **A dictionary keyed by strings** is an object whose members, named anything, are each its
  value's type (`additionalProperties`).
- **A type that codes itself by hand** writes its schema by hand, as a `SchemaDescribed`: Arrows'
  `ArrowTerminal`, an object with one member, `free` or `bound`, is `oneOf` the two.
- **A value that names shapes** (`ShapeNaming`, a mention) is found through the lists: a struct
  that holds one adopts `ShapeNaming` too, and the registry refuses one that doesn't ([Values that
  name shapes](#values-that-name-shapes)).
- **Every list holds up.** A property is named after its member. As it's built, the registry
  describes every kind's schema and every added property's, and refuses a list, of any struct those
  reach (a kind's props, a struct inside them or behind a hand-written schema, an added property's
  value), that misses a stored member (a board would never save it), names one it doesn't have or
  whose key path isn't that stored member (a computed view, or part of one), lists one twice or has
  two properties write one member; an optional that's `required()` (a nil
  one wouldn't save) or has a default that isn't nil (a nil one would read back as the default);
  and optionals inside a collection or another optional, which a schema can't say (nor may an
  added property's value be an optional, or hold one). It refuses two types under one definition
  name, a struct that holds itself with no name, and a schema that can't be checked against (a
  `$ref` to a place the schema doesn't have, or one that leads back to itself before going into the
  value, and a `pattern` that isn't a regular expression). The first problem is the one reported,
  and a problem in a property's value is its declarer's:

  ```
  Shapes: unlisted (from kinds): Unlisted.note isn't in Unlisted's properties, so boards wouldn't save it
  ```

Changing the list changes what boards hold. A member renamed, removed or retyped, or a new one, takes
a step in the kind's `migrations` and a fixture for the new version ([Boards on disk](#boards-on-disk)).

### Added properties

A plugin can give other plugins' kinds a property: something their shapes know that the kinds don't
declare. The property is a type, as a tab or an extension point is, and says everything about itself
once ([Checklists](../Sources/Checklists/Checklists.swift)):

```swift
public enum ChecklistProperty {}
extension ChecklistProperty: ShapeProperty {
    public static let key: PropertyKey = "checklist"
    public static var defaultValue: [ChecklistItem]? { [] }
}
```

- **`key`** is where boards keep its values, and its name in each kind's schema. It's unique among
  added properties, never one of an opted-in kind's own property names, and never changes once
  shipped. The id audit holds a `PropertyKey` literal to the module that declares it, as it does a
  kind ([The module graph](#the-module-graph)).
- **`defaultValue`** is what every shape of a kind that opts in has until it's changed: every note
  has a checklist, empty. Nil means only the shapes it's set on have one, and setting it to nil
  removes it.
- **`keywords`** is what its schema says beyond its value's type, in the modifiers a kind's own
  properties take (none by default). Titles' title is one to 80 characters:
  `PropertyKeywords().description("What the shape is called.").minLength(1).maxLength(80)`, and a
  shape whose title is longer gets a warning ([Checking shapes](#checking-shapes-against-their-schemas)).
- **`isNone(_:)`** says which values are no value at all (never, by default): Titles' says a blank
  title, `title.allSatisfy(\.isWhitespace)`. No shape holds one: setting one sets nil, or the
  default for a property that has one (which can't itself be none), and a board's reads as none,
  so the shape has the default. A value a board writes as null, among the added values, kept, or
  handed over from a kind's own member, is none too.
- **`migrations`** is its history (`PropertyMigration`s, none by default), its own whatever kinds
  opt in ([Boards on disk](#boards-on-disk)).
- **The value** is `SchemaDescribed`, `Codable`, `Equatable` and `Sendable`: a scalar, an array, or
  a `SchemaDefined` struct.

**Declaring and opting in.** The plugin that owns the property declares it, and a kind opts in, one
of three ways:

```swift
registrar.declare(ChecklistProperty.self)                   // the owner, ChecklistsPlugin; one plugin per key
note.optIn(to: ChecklistProperty.self)                      // a kind, inside registrar.shape { note in ... }
registrar.optIn(Ellipse.self, to: ChecklistProperty.self)   // another plugin's kind, from a bridge
registrar.optInEveryShape(to: P.self, where: { !($0 is any PaintOrderAnchored) })   // every kind, or those a definition picks
```

A kind opts into a property once: its own opt-in and an every-shape one can't both hold. It rarely
calls `optIn(to:)` itself: the horizontal's sugar does, and brings the rest. `note.checklist()` opts
the note in, then contributes the chip flag, the Checklist tab and the bulk actions
([Checklists](#a-horizontals-feature-tab-checklists)).

**Reading and writing.** A shape's value is `record[ChecklistProperty.self]`, on an
`AnyShapeRecord` or a typed `ShapeRecord<StickyNote>`, beside its props; nil if it has none. It
changes as the props do, in a transaction:
`tx.update(id) { $0[ChecklistProperty.self]?.append(item) }`. What a kind derives from both goes on
its record: a note is empty with no text, no title and no items (`isEmpty` on
`ShapeRecord<StickyNote>`), and a task's summary and remaining hours count its checklist (`summary`
and `remaining` on `ShapeRecord<TaskCard>`).

- **Writes that can't hold are dropped**, as a frame that isn't finite is: a value set on a kind
  that doesn't opt in, nil for a property with a default, and anything set on a value or a shape
  kept aside ([Boards on disk](#boards-on-disk)). Setting the value a shape has commits nothing.
- **Defaults are filled in where shapes enter an editor**: an insert (placing, pasting),
  `CanvasEditor.init`, `replaceDocument`, and reading a board. Filling them adds no commit of its
  own and never marks a board edited: `init` commits nothing, `replaceDocument` (and so opening a
  board) makes its one commit with the defaults in it, which services hear but which doesn't mark
  the board edited, and an insert is an edit anyway. `registry.fillingDefaults(document)` does the
  same to a document.
- **Copies keep them**: `record.copy(as:)` takes the values along, as it does the metadata.
- **A placement can set one** on what it places: TaskCards' tool places a task titled "New Task"
  with `task.placement(size: size) { TaskCard() }.setting(TitleProperty.self, to: "New Task")`.

**The registry** refuses an opt-in to a property no installed plugin declares, two declarations of
one key, a kind opted in twice (by one plugin or two), and a kind opting into a property named like
one of its own:

```
PropertyOptIns: ratings opts box into property stars, which no installed plugin declares
ratings and more both claim box's stars in PropertyOptIns
PropertyOptIns: rated has a property of its own named stars, so it can't opt into the one ratings declares; hand the member over to it (PropsMigration.handOver), or rename one
```

Its report shows each declaration and opt-in: `property checklist` on the owner's line (`property
checklist v1` once it has a migration), `property checklist → sticky-note` on the line of the plugin
that opts a kind in, and `property … → every shape` for `optInEveryShape`. In code,
`registry.declaredProperties`, `registry.properties(for: kind)` (in plugin order) and
`registry.owner(of: key)`.

**In the panel and the menu.** DetailPanel and ContextMenus take sections and items over an added
property's value:

| Sugar | For |
|---|---|
| `x.details(of: P.self) { sections }` | Sections over the value, on this kind's shapes that have one: what a horizontal's sugar contributes for the property it opts the kind into (Checklists' Items and Progress). |
| `registrar.details(of: P.self) { sections }` | The same, on every shape that has one, whatever its kind. |
| `x.contextMenu(of: P.self) { items }`, `registrar.contextMenu(of: P.self) { items }` | Items over the value, on this kind's shapes, or every shape, that have one (Checklists' bulk actions). |

A section gets a `ShapeBinding` of the value (`$items`, a `ShapeBinding<[ChecklistItem]>`), and
each write is one transaction on that shape's value; an item edits it in place
(`{ action.apply(to: &$0) }`). A kind's own sections and header read an added value through the
shape the panel drew: `$task.shape[ChecklistProperty.self]`, and bind one, nil while the shape has
none, with `$task[TitleProperty.self]` (a `Binding<String?>`: `TitleHeader($task)` renames through
it) ([`ShapeBinding`](#reading-and-writing-shapebinding)).

### A kind's schema

`registry.schema(for: kind)` is a kind's properties as one JSON Schema (draft 2020-12): an object
with each of its own properties, then each added property it opts into, marked with its owner
(`x-canvas-owner`) and its default, if it has one; only properties marked `required()` are
`required`, and nothing else is allowed.
Shared definitions are under `$defs`, named after the modules that declare them (`core.rect`, `checklists.item`,
`arrows.terminal`), and every `$ref` is local. The sticky note's, abbreviated (CompositionTests pins
it whole):

```json
{
  "$defs" : {
    "checklists.item" : {
      "additionalProperties" : false,
      "properties" : { "id" : { "format" : "uuid", "type" : "string" }, "isDone" : { "default" : false, "type" : "boolean" }, "text" : { … } },
      "required" : [ "id" ],
      "title" : "Checklist item",
      "type" : "object"
    },
    "core.rect" : { "description" : "[[x, y], [width, height]], in world units", "type" : "array", "prefixItems" : [ … ], … },
    …
  },
  "$id" : "tag:infinite-canvas,2026:kinds/sticky-note",
  "$schema" : "https://json-schema.org/draft/2020-12/schema",
  "additionalProperties" : false,
  "properties" : {
    "checklist" : { "default" : [], "items" : { "$ref" : "#/$defs/checklists.item" }, "type" : "array", "x-canvas-owner" : "checklists" },
    "frame" : { "$ref" : "#/$defs/core.rect" },
    "text" : { "default" : "", "description" : "What the note says.", "type" : "string" },
    "title" : { "description" : "What the shape is called.", "maxLength" : 80, "minLength" : 1, "type" : "string", "x-canvas-owner" : "titles" },
    …
  },
  "required" : [ "frame" ],
  "title" : "Sticky note",
  "type" : "object"
}
```

It describes a shape as one object, own and added properties side by side, as whatever reads or
writes a shape (an agent, a form) sees it. A board keeps the two apart, `props` and `added`, each
with its own versions ([Boards on disk](#boards-on-disk)), so a plugin's property comes and goes
without touching the kind. CompositionTests also checks that every shipped kind's schema describes
its fixture, and that every fixture holds up against it.

### Checking shapes against their schemas

`registry.schemaViolations(of: shape)` is where a shape breaks its kind's schema: its properties,
own and added, as one object (`record.propertiesJSON`, each as a board writes it), checked against
`schema(for:)`, one `SchemaViolation` for each keyword broken at each place. Empty when it holds
up, and for a shape kept aside. Each kind's schema is compiled once, as the registry is built
(`SchemaValidator`, which checks any JSON against any schema: `schema.violations(of: json)`), so a
schema it couldn't check refuses the plugin list then, rather than warning on every shape
(`validator.problems` says what's wrong with one).

```swift
registry.schemaViolations(of: note).first
// /title maxLength: Title is 95 characters long, and should be at most 80.
//   path [.member("title")], property "title", pointer "/title", keyword "maxLength"
```

Typed props always have their schema's shape (the types, `required`, nothing else allowed), so
what a shape can break are the bounds its properties declare (`maxLength`, `minimum`, `pattern`,
`multipleOf`, ...), and a number that isn't finite, which a board writes as the string "nan" or
"inf". A message names the place by its schema's `title`, else by its path ("Title", "Checklist ›
item 3 › text"), and says what's wrong in the value's terms, so a message reads well where people
see it.

The checker is 2020-12's validation vocabulary (`type`, `enum`, `const`, the bounds on numbers,
strings, arrays and objects, `required`, `dependentRequired`) and its applicators (`properties`,
`patternProperties`, `additionalProperties`, `propertyNames`, `prefixItems`, `items`, `contains`,
`allOf`, `anyOf`, `oneOf`, `not`, `if`/`then`/`else`, and `$ref` to any place in the same schema).
`format` is an annotation, as 2020-12 has it, and so is any keyword it doesn't know
(`x-canvas-owner`): neither is checked. It compares as JSON Schema does: strings code point for
code point (so "é" and "e\u{301}" differ, where Swift's `==` equates them), numbers by value. A
length is in code points too: a thumbs-up with a skin tone is two, so a message gives both counts
when they differ ("82 characters long as JSON Schema counts them (41 as shown)"). A pattern is
ECMA-262's, run by ICU (`NSRegularExpression`) once what ICU reads differently is rewritten: `$`
ends the string (ICU's also matches before a final line break), `.` and `\s` are ECMA's, and `\d`,
`\w` and `\b` are ASCII. A pattern ICU can't read at all (a lookbehind of no fixed length) refuses
the plugin list, as one that's no regular expression does.

**Validation turns each violation into a warning.** The rule is Validation's own, for every kind
(`ValidationRules` on its line of the report), after the kind's own rules: the violation's message,
about the property it's in (`ValidationIssue.field`). So a bound is a guideline a shape can
break and still work: it's outlined orange, listed in its Issues tab, and dotted in the table of
contents, and it saves as it is. A rule that should refuse a shape is the kind's, as an error. The
engine checks a shape when it changes, as it does every rule, and reads every shape once, on the
first frame after a board opens: `./build.sh bench` holds that to 100 ms for 10,000 shapes. A shape
keeps what its schema said until a commit changes it other than by moving it (`ChangeSet.moved`),
since where a shape is is nothing its schema checks: a drag that moves 10,000 shapes redoes their
rules, not their schemas, and so does undoing or redoing it.

### Properties and metadata

A property is what a shape knows: a note's text, its checklist. It's in the kind's schema, for
anything that reads or writes shapes. [Metadata](#metadata) (`ShapeMeta`) is what a plugin keeps
*about* a shape, such as the shape it was copied from (Clipboard's `CopiedFrom`): typed by its
owner's key, but in no schema, and unversioned. Something the shape says is a property; something
said about it is metadata.

### Values that name shapes

Some values name other shapes: a mention in a note's text names the shape it mentions. The core
keeps them right without knowing what they are, through `ShapeNaming`, the second form of one
concern, references between shapes. The first is bindings, the `ShapeReferencing`
[capability](#capabilities). Both go through one entry, `record.remappingReferences(_:in:)`.

| | Bindings (`ShapeReferencing`) | Names (`ShapeNaming`) |
|---|---|---|
| Adopted by | a kind's definition | a value, wherever a shape keeps it |
| For | an arrow's bound ends | a mention |
| The shape it's bound to, or names | must be on the board | may be gone |
| Deleting it | lets go of it, in the deleting transaction | changes nothing: no delete looks for names, so the name stays, and names the shape again if it comes back with its id |
| Copying without it | lets go of it (an arrow's end stays where it's drawn) | keeps naming the original |
| Copying with it | is bound to its copy | names its copy |
| `canvas create` with one that isn't there | refused (`A tag can't be bound to shapes that aren't on this board: …`) | made, with a warning |

```swift
/// A leaf: it holds the id itself (coded by hand, as the id), so it implements both.
public struct Citation: Hashable, Sendable, Codable, SchemaDescribed {
    public var shape: ShapeID
    ...
}
extension Citation: ShapeNaming {
    public func forEachNamedShape(_ body: (ShapeID) -> Void) { body(shape) }
    public func renamingShapes(_ rename: (ShapeID) -> ShapeID?) -> Citation { Citation(rename(shape) ?? shape) }
}

/// A struct that holds names adopts it too, with nothing to write: its listed members' names.
public struct MemoNote: SchemaDefined, Hashable {
    public static let properties = Properties<MemoNote>(definition: "memo-note") {
        Property("text", \.text)
        Property("cites", \.cites)
    }
    public var text: String
    public var cites: [Citation]
}
extension MemoNote: ShapeNaming {}
```

(These are CanvasTesting's fixtures, with `NamingPlugin`: a `Memo` kind holding names in a struct in
a list, an optional, a dictionary and an added property, `CitationsProperty`, and a `CitingTag`
that both binds and names.)

- **Found through property lists.** A kind's props are walked by their list, so they needn't adopt
  `ShapeNaming`: a property whose member's type is `ShapeNaming` names shapes. The list finds out
  once, with a runtime check like the one it makes for optionals, so a property that names nothing
  carries nothing, and a kind with no names costs nothing. A struct in the props (or in an added
  value) adopts `ShapeNaming` in an extension, with nothing to write. Optionals, arrays, sets
  (renaming rebuilds the set) and dictionaries keyed by strings of names are names, and so is an
  added property's value, whatever kinds opt in. A leaf, a type coded by hand, implements
  `forEachNamedShape` (each id, repeats included) and `renamingShapes` (pure; nil keeps a name).
- **What the registry refuses.** A struct that holds names without adopting `ShapeNaming`, in a
  kind's props or an added property's value, since nothing could find its names and a copy would go
  on naming the originals:

  ```
  Shapes: annotated (from kinds): Footnote.cite names shapes (ShapeNaming), so Footnote must adopt ShapeNaming too (extension Footnote: ShapeNaming {}), or a copy would go on naming the originals
  ```

  It can't look inside a type coded by hand, as it can't check its list.
- **Reading them.** `registry.namingKinds` are the kinds whose props, or the added properties they
  opt into, can hold names; no other shape holds one, so a plugin that follows names (backlinks)
  walks only those. `record.forEachNamingValue(in: registry) { property, value in
  value.forEachNamedShape { id in … } }` is each value in a shape that names shapes, with the
  property it's in: the kind's own in list order, then its added ones. A shape kept aside has none,
  and neither has an added value kept aside (a newer version's), which a copy doesn't rename either:
  it goes on naming the originals. A plugin that reads leaves of its own (Mentions' text) goes into
  each value with `value.forEachNamingLeaf { leaf in … }`: each leaf wherever it is in the value (a
  struct's listed members, a list, an optional, a set, a dictionary), a leaf being its own one, so
  it finds its leaves however deep a kind keeps them.
- **Copying.** `record.remappingReferences(map, in:)` does both forms: first what the kind binds, as
  its `ShapeReferencing` says (nil lets a binding go), then every name, for `namingKinds` (nil keeps
  a name). A definition remaps what it binds and leaves names to the core. Clipboard's copy and
  paste go through it, so a note pasted with the shape it mentions mentions the copy, and one
  pasted alone mentions the original.
- **Deleting.** A delete lets go only of bindings: it asks only the kinds that bind, never a kind
  that only names, so deleting a shape writes nothing into the shapes that name it. On a kind that
  does both (`CitingTag`), a delete lets its binding go and keeps its names.
- **Bound, or named.** `record.boundShapes(in:)` is what a shape is bound to, what must be on its
  board, each once; the shapes it only names aren't in it. [`canvas create`](#the-command-line)
  checks it.

## Selection

Selecting is a horizontal ([`Sources/Selection`](../Sources/Selection)), and the one most others
build on. It owns what's selected and the way back through it, the hovered shape, the Select
tool (V) and its marquee, the handles of the one selected shape, and what Delete, Return, ⌘A and
Back do. The core has never heard of a selection: Selection works through the same generic hooks
any plugin can use.

| Core hook | What Selection does with it |
|---|---|
| `registrar.defaultTool(.select)` | The editor starts in Select, Select leads the toolbar, and Escape and placing a shape come back to it. |
| `registrar.outlines { ... }` | Each selected shape's outline, the box around several, and the hover's faint outline. The core strokes every plugin's outlines and the hint in one pass, over the faint ones. |
| `registrar.command(.delete)`, `.selectAll` and `.goBack` (with their keys, through Keyboard) | Delete, and Edit › Delete, deletes the selection; ⌘A, and Edit › Select All, selects everything; ⌘[, and Go › Back (enabled while there's a step back), goes back to the previous selection. Return (a shortcut of its own) edits the only selected shape. |
| `Tool.cancel` | Escape in Select, with nothing under way, deselects. |
| `Tool.ignoresPress` | The rest of a double-click whose first click, on a face, went somewhere (changed the selection or moved the camera) is ignored, so the camera goes on and nothing is placed or edited where it's brought. |
| `EditorService.documentDidChange`, `didPlace` | Drops shapes that are gone (or no longer selectable) from the selection and the hover; selects a shape just placed. |
| `Session.draw(in:)` | The marquee draws itself. |
| `TranslatingSession`, `editor.shape(at:where:)` | Dragging the selection moves it; presses and hover find the front-most selectable shape. |

Its state is `CanvasEditor` members that only modules importing Selection see. Without
`SelectionPlugin` installed they're empty and ignore sets.

- `selectedShapeIDs` is every selected shape, in the order selected; `selection` is the only
  selected one, nil when none or several are (tldraw's onlySelectedShape), and setting it selects
  exactly that shape. Handles, Return, editing and the arrows' binding hints follow `selection`, so
  they apply to a lone shape. Both only ever name selectable shapes that exist, and setting what's
  already selected changes nothing (no redraw, no Observation notification).
- `selectionRevision` goes up by one on every change to the selection, as `editor.revision` does
  for the document, so a plugin that selected something can tell whether its selection is still
  the one in place, even after the same shapes were deselected and selected again (the table of
  contents does).
- `hovered` is the shape the pointer is over. The select tool sets it on the canvas and clears it
  as the pointer leaves; any other plugin may set it where it shows shapes (the table of contents'
  rows do), in any tool, and changing tools clears it. It's outlined faintly (not while a session
  runs, nor on a selected shape): wider and lighter than the selection's (2.5 points, the accent at
  60%), easy to see over a yellow note, but a hovered shape doesn't read as selected
  as it would in tldraw, which strokes a hover like the selection. `isHovered(_:)` says whether
  one shape is hovered, and is observed per shape: its observers hear only that shape's hover
  change, not the hover moving between two others, so a view per shape (a row of the table of
  contents) redraws only when its own shape's hover does. Observation keeps observers by key path,
  and each shape has its own, `\.[hovering: id]`.
- `goBack()` and `canGoBack` are data-canvas's selection history. Each change of the selection
  puts the selection it leaves on a stack, with the camera as it is at that moment (or, while it
  glides, `editor.cameraTarget`, where it's headed): a click, a row of the table of contents,
  Escape, a deletion. Going back takes the last one off, selects its shapes (less any that are
  gone) and animates the camera back over 200 ms, as data-canvas does. The detail panel's header
  has the back button, and Go › Back (⌘[) works whatever has the keyboard, but not mid-gesture.
  The stack holds 50 steps, skips a repeat of the step below, and going back skips a step that
  would change nothing: its shapes are all gone (unless it selected nothing, the board's list), or
  they're what's selected. `canGoBack` is true only when a step wouldn't be skipped, so after
  deleting the only shape selected there's no Back. It's per editor, so per window, and isn't
  saved. Two differences from data-canvas: a press of the select tool and its drag
  are one step, so a marquee goes back to what was selected before the press, where data-canvas also
  keeps the moment the press on empty canvas deselected; and a step keeps the camera as the
  selection was left, not as it was made, so going back from a row's details returns to the list
  as it was before the zoom. There's no forward.
- `reveal(_:)` and `goTo(_:)` are the one way to bring shapes into view, for every plugin (the
  table of contents' rows, a mention followed out of text). `reveal` only moves the camera: it
  centers the shapes' bounds (`shapeContext.bounds(of:)`), zoomed to fit with 100 points of margin
  in all but no closer than 120%, over 200 ms, as data-canvas's table of contents does (tldraw's
  zoomToBounds). It's what selecting rows does, and does nothing before the view has a size.
  `goTo` goes to shapes as following a link to them does: it ends editing, selects those that can
  be selected, and reveals them unless they're all in view already at a readable zoom. Selecting
  them is a step back when it changes the selection, so ⌘[ returns, camera and all; going to
  what's selected already, or to shapes none of which can be selected, leaves the selection as it
  is, takes no step, and only moves the camera. Readable is 70% or closer
  (`SelectionStyle.readableZoom`: a note's 16-point text reads at 11.2 points there, just over
  `NSFont.smallSystemFontSize`, the smallest macOS sets text to be read at), or, for shapes too big
  to show whole at that, as close as fitting them would bring them, so going to a big shape that's
  all in view never zooms out to show what's shown. The camera is judged where it's headed
  (`cameraTarget`). `goTo` does nothing mid-gesture, or when none of the shapes is on the board;
  without `SelectionPlugin` it ends editing and reveals. data-canvas's navigateToShape always
  zooms.
- `hoveredHandle`, `brush` (the marquee), `selectionBounds`, `isSelectable(_:)`, and the commands'
  `selectAll()`, `deleteSelection()` and `editSelection()`.

**Opting out.** Every kind is selectable unless it says otherwise, for all its shapes or for some:

```swift
registrar.shape(BackdropDefinition()) { backdrop in backdrop.unselectable() }
registrar.shape(GhostDefinition()) { ghost in ghost.selectable { $0.props.isShown } }
```

The select tool sees through such a shape: a press lands on whatever is beneath it (or on the
canvas, where a drag is a marquee), and the marquee and ⌘A pass it by, so it's never selected,
outlined on hover, or shown in the detail panel. It still draws, and everything else treats it as
usual: arrows bind to it, the eraser erases it, code moves and deletes it. A place tool still puts
one down and drags it, with nothing selected; a double-click on it goes to what's beneath, so an
unselectable `Editable` kind is edited only as it's placed. A shape that stops being selectable
leaves the selection with the change that did it. The rule is `ShapeSelectability`: at most one per
kind, plus one for every kind, which a kind's own overrides.

**Read-only shapes** (a locked one: [Locking](#locking)) are another matter: they're pressed,
hovered, selected and outlined as any other, and only what would change them is refused. A drag
leaves them where they are and moves the rest of the selection, Delete deletes the rest, Return
and a double-click don't edit them, and they show no handles, so a press where one would be
presses the shape. Each try reaches the plugin that made them read-only, which says why (Locking
shakes them).

**Opting in** to the rest:

- `note.createOnDoubleClick(place)` fills `DoubleClickPlacement`: what a double-click on empty
  canvas places, at most one kind. StickyNotes does, so it can't be installed without Selection.
- `HandleProviding` is Selection's capability: handles on the only selected shape. The select tool
  finds, draws and hit-tests them; the definition says what a press and a drag do.
- `BrushHitTesting` is Selection's capability for a kind that decides for itself whether the
  marquee touches it. The default is `ShapeGeometry.isHit(byBrush:)`, from its geometry.
- Arrows (to select the arrow it draws, and for its handles), DetailPanel (to follow the selection),
  ContextMenus (the menu is for the selection), TableOfContents (to list and select shapes) and
  Ports (its dots are [canvas buttons](#canvas-buttons)) and Adornments (a clickable adornment is a
  canvas button, and every adornment is its shape's through `DecorationHits`) import Selection too.

**The select tool** follows tldraw's states. A plugin's [canvas buttons](#canvas-buttons) win,
then handles, then the selectable shape under the pointer, or [something drawn for it outside
it](#drawn-for-a-shape-decorationhits) (a title's pill), then empty space inside a
multi-selection's box, then the canvas.

- A press on a shape selects just it, and leaves it where it is in the paint order (as tldraw
  does; the POC brought it to the front); ⇧ adds it. With ⌘, or on a
  shape already selected, the press keeps the selection, so a drag past the 4-point threshold
  moves it all; released without a drag, it selects the shape under the release (⇧ or ⌘ toggles it
  instead). A lone box pressed without ⇧ or ⌘ follows the pointer from the press, with no
  threshold. A double-click edits an `Editable` shape, selected alone.
- A plain press on a [face](#faces-clickable-parts-of-a-shape) (a mention's pill in a note) is
  still the shape's, but waits for the threshold, even on a lone box, so that a release within it
  clicks the face; a double-click there is the face's too, in place of editing.
- A press on empty canvas deselects (not with ⇧ or ⌘); a drag from there is a marquee, the brush.
  It selects as it goes: whatever it touches, or with ⌘ only what it strictly encloses; ⇧ adds to
  the selection from before. ⇧ and ⌘ take effect as they're pressed or let go, and a ⌘-drag from a
  shape brushes too.
- A drag from empty space inside a multi-selection's box moves the selection; a click there is a
  click on the canvas.
- The selection stays outlined while it moves, box and all (tldraw, and the POC, hide it). Only
  a session that `hidesOutlines` (dragging an arrow's handle, or drawing an arrow) takes the
  outlines away.
- ⌘ is the Command key only: Control-click is a secondary click on the Mac, so it never presses
  here (`pointer.isControlClick`). It opens the context menu, if there is one.
- Escape while a shape is pressed, before the drag threshold, ends the press; mid-marquee it puts
  back the selection from before. A press on empty canvas ignores Escape until the release, as in
  tldraw.

### Canvas buttons

A plugin can put a button on the canvas: something it draws in an overlay that a click does
something with, as the lock chip unlocks its shape ([Locking](#locking)), or that a drag starts
something from, as a port's dot draws an arrow ([Ports](#ports)). It says where its buttons are,
and what a click on one, or a drag from one, does; the select tool does the rest. Adornments does
it for every [clickable adornment](#pointing), the lock chip among them, so a button shown on a
shape is a `ClickableAdornment`, and needs no call of its own:

```swift
registrar.canvasButtons(at: { editor, viewPoint in editor.adornmentState?.button(atViewPoint: viewPoint) },   // any Hashable, or nil
                        click: { button, editor in editor.adornmentState?.click(button) })
registrar.canvasButtons(at: { editor, viewPoint in state.dot(atViewPoint: viewPoint) },
                        drag: { dot, origin, editor in state.connect(from: dot, at: origin) })     // a Session, or nil
```

- **Buttons come first.** A press on one, in the select tool, is the button's, whatever is under
  it: a handle, a shape, the selection's box. Where two plugins' buttons overlap, the later
  plugin's wins, as its overlay draws on top. A button neither selects nor moves anything by
  itself.
- **A click** is a press and a release on the button, as an NSButton's is; dragged off, the press
  does nothing (and Escape lets go of it).
- **A drag**, past the drag threshold (4 points), goes to the session `drag` returns, given the
  button and where it was pressed (world units); the press hands it over, and the session gets
  the drag event that crossed the threshold. Nil ends the press. Released without a drag, the
  press does nothing, and Escape lets go of it.
- **Hover and press.** The pointing hand (`CanvasCursor.pointingHand`) shows over a button that's
  clicked; the open hand over one that's dragged, and the closed hand while it's pressed.
  `editor.hoveredButton` and `editor.pressedButton` say which the plugin should draw hovered and
  pressed, and the canvas redraws as they change; a drag that's handed over clears both.
- **Where the pointer is.** `editor.pointerOverCanvas` is where the pointer is over the canvas in
  the select tool, in view points, as it last moved with nothing under way: nil once it's left the
  canvas or gone over the minimap or the editing view, while another tool is current, and once Escape lets go of a
  dragged button's press, until the pointer moves again (the select tool doesn't see a held press
  move). A plugin whose buttons show
  only while the pointer is near them goes by it (a port's dots).
- **Only in the select tool.** In any other tool a button is only drawn, and a press there is the
  tool's: the hand pans over a lock chip, and the eraser erases under it.
- **Buttons that come and go** with the document are looked for again under a still pointer after
  each commit. One that comes or goes some other way (a chip fading out) calls
  `editor.canvasButtonsDidChange()`, as `editor.adornmentsDidChange(for:)` does for an adornment.
- **Keep `at` cheap**: the select tool asks it as the pointer moves. Adornments' looks only where
  an adornment could be, through `editor.paintOrder(in:)`, and at nothing when no plugin places a
  clickable one; Ports' at the dots of the few shapes near the pointer, and at what covers them
  only for a dot within reach.

### Drawn for a shape: DecorationHits

What a plugin draws for a shape outside it can count as the shape: a title's pill above a note is
the note's. `DecorationHits` is Selection's point for that. A plugin says which shape, if any, has
its drawing under a world point, of those `include` accepts, the front-most; Adornments does it for
every adornment:

```swift
registrar.decorationHits { editor, point, include in editor.adornmentState?.shape(at: point, where: include) }   // a ShapeID, or nil
```

- **A point on it is a point on its shape.** `editor.selectableShape(at:)` asks every plugin's
  first, the last plugin's first (such drawing is above every shape), then the shapes. So a press
  there selects the shape (⇧ and ⌘ as on the shape), a drag from it moves the shape (a lone box
  follows from the press), a release is hit again, hover hovers the shape (and tints its row in
  the table of contents), a double-click edits an `Editable` shape (and never places a note there,
  as a double-click on empty canvas would), and a right-click opens the shape's menu.
- **`include`** is the select tool's rule, `isSelectable`: an unselectable shape's drawing is seen
  through, as the shape is.
- **Buttons still come first.** A [canvas button](#canvas-buttons) under the pointer takes the
  press and the hover, so a clickable adornment (the lock) is clicked, and anything else drawn for
  a shape is the shape. A right-click asks no button, so on the lock it opens its shape's menu.
- **Only what the select tool and the menu see.** The core's `editor.shape(at:)` is as it was, so
  the marquee and ⌘A (which go by geometry), the eraser and the arrow tool (an arrow never binds
  through a pill) go by the shapes alone, and the hand tool pans over it.
- **Keep it cheap**: the select tool asks it as the pointer moves. Adornments looks in a thin strip
  around the point, through `editor.paintOrder(in:)`.

### Faces: clickable parts of a shape

Some of a shape's content answers a click, yet mustn't take the shape's press: a mention's pill in a
note's text, a link, a checkbox drawn on a card. A canvas button would take the press, so the note
couldn't be selected or dragged by its pill. A face is Selection's answer (the `ShapeFaces` point): a
press on one is the shape's, and only the click, the double-click and the hover are the face's. A
plugin says where its faces are on a shape and what they do:

```swift
registrar.shapeFaces(at: { editor, shape, point in pills.pill(in: shape, at: point) },    // any Hashable, or nil
                     click: { pill, editor in
                         if !editor.isReadOnly(pill.shape) { editor.beginEditing(pill.shape, at: pill.center) }
                     },
                     doubleClick: { pill, editor in editor.goTo([pill.target]) },           // optional
                     hovering: { pill, _ in pill.target })                                  // optional: the shape to hover
```

- **Asked only on a plain press, on the shape.** The select tool asks `at` only for a plain press
  (no ⇧, ⌘ or ⌥; a Control-click presses nothing), and only about the shape it would press there
  (`editor.selectableShape(at:)`), selected or not, with a world point on that shape itself: a point
  on [something drawn for a shape](#drawn-for-a-shape-decorationhits) (a title's pill, over this
  shape's face or another's) is that drawing's shape, and no face's. Canvas buttons and handles come
  first, as for any press. With ⇧, ⌘ or ⌥ held, a press on a face is the shape's, as anywhere on
  it: ⇧ adds the shape, ⌘ toggles it.
- **Keep `at` cheap**, and to the one shape it's given: the select tool asks it as the pointer moves
  over any shape. With no plugin's faces, nothing is asked.
- **The press is the shape's.** It selects the shape as any press does (a member of several keeps
  them all). Past the drag threshold it moves the selection from the press, as the shape's own press
  would. On a lone box, which a press anywhere else moves at once, a press on a face waits for the
  threshold, so that a click there doesn't nudge it: an intended difference from the select tool's
  lone box, which SelectionTests pin.
- **A click** is a press released within the threshold: the shape is selected alone, and `click`
  runs. Escape before the release lets go of the press, and nothing is clicked. The press is over
  as `click` runs, so it may go to shapes (`editor.goTo`) or back, which do nothing mid-gesture, and
  what it selects is a step back of its own. `click` isn't given the press, so a face that needs a
  point keeps where it is in its value: a pill edits its shape from there
  (`editor.beginEditing(id, at:)`, which the editing view reads as `EditContext.startPoint`).
- **A read-only shape's face clicks too** (a locked note's pill): the press selects the shape, as
  any press on it does, and `click` runs. A face that edits its shape checks `editor.isReadOnly`
  first, as the example does: editing a read-only shape is refused, and a refusal is a try to
  change it, which services hear (`didRefuseChanges`, which Locking answers with a shake), while a
  click on a locked shape is no try. CompositionTests' `pillsPlugin` does the same, and its test
  holds a locked note still through a click on its pill and a double-click.
- **A click that goes somewhere** (it changes the selection, or moves the camera: a link's `goTo`)
  makes the rest of its double-click its own. The select tool ignores each press after it with a
  click count of 2 or more (`Tool.ignoresPress`), until one with a count of 1: the camera goes on
  to where the click sent it, and nothing the moving camera has brought under the pointer is placed
  (a double-click on empty canvas), edited, pressed or brushed. So a link is followed once, however
  it's clicked. A click that goes nowhere (a pill's, which edits its note, or does nothing on a
  locked one) leaves the double-click to the face's `doubleClick`, as below.
- **A double-click** whose press lands on a face selects the shape alone and runs `doubleClick`, in
  place of what a double-click does to the shape (editing an `Editable` one); it runs on a read-only
  shape too (a locked note's pill), where editing would be refused. Without `doubleClick`, a
  double-click there edits an `Editable` shape, and is otherwise one more click on the face. Where
  `click` begins editing, the double-click's second press lands in the editing view the click
  opened, not on the canvas, so the view answers it; `doubleClick` runs where editing was refused.
- **Hover.** The pointer over a face, in the select tool, hovers the shape `hovering` names
  (`editor.hovered`: outlined faintly, its row tinted in the table of contents), in the face's
  shape's place (a pill's target); nil, a shape that isn't there or can't be selected, or no
  `hovering`, hovers the face's shape. It's asked whatever keys are held. The cursor stays the arrow:
  a face isn't a button. A `click` that begins editing leaves the pointer over the editing view,
  which has it ([the views the canvas hosts](#the-editor-the-document-and-drawing)), so the hover
  ends with the release.
- **Where to draw them** is the plugin's: a face is found where the shape's render (or an overlay)
  draws it. Several plugins' faces are asked the last plugin's first.

## Keyboard shortcuts

What each key does on the canvas is a horizontal too ([`Sources/Keyboard`](../Sources/Keyboard)).
Every key is registered with it, one shortcut per chord, by the plugin that gives the key its
meaning: a tool's letter, Delete, Return, Escape, ⌘A. The core has never heard of a shortcut: it
hands each key pressed on the canvas to the one plugin that claims key strokes, and Keyboard does.

```swift
rectangle.tool(label: "Rectangle", systemImage: "rectangle", shortcut: "r", placing: place)            // Rectangles
registrar.tool(ToolDescriptor(id: .select, label: "Select", systemImage: "cursorarrow"), shortcut: "v") { _ in SelectTool() }
registrar.command(.delete, shortcuts: [.delete, .deleteForward]) { $0.deleteSelection() }                // Selection
registrar.shortcut(.return, "Edit Selection") { $0.editSelection() }
registrar.shortcut("h", forTool: .hand)                                                                 // Keyboard itself
registrar.shortcut(.escape, "Cancel") { $0.cancel() }
registrar.shortcut(KeyChord("z", .command), forCommand: .undo, repeats: true)
```

| Sugar | For |
|---|---|
| `x.tool(label:systemImage:shortcut:placing:)` | A place tool, and the key that switches to it. |
| `registrar.tool(descriptor, shortcut:) { ... }` | Any tool, and its key. |
| `registrar.shortcut(chord, forTool:)` | A key for a tool registered elsewhere: Keyboard gives the core's Hand its H this way. |
| `registrar.command(command, shortcuts: [...]) { ... }` | A command (what a menu item runs) and the keys that run it, so the menu and the keys do one thing. |
| `registrar.shortcut(chord, forCommand:, repeats:)` | A key for a command claimed elsewhere: Keyboard gives the core's undo and redo ⌘Z and ⇧⌘Z this way. |
| `registrar.shortcut(chord, "Title", when:, repeats:) { editor in ... }` | A key that does something of its own. |

What the shipped app's keys do:

| Key | Does | Registered by |
|---|---|---|
| V, H, A, N, O, T, R, L, E | Switches to that tool | The tool's plugin; H by Keyboard, for the core's Hand |
| ⎋ (and ⌘.) | Cancels: the drag under way, else the tool's own Escape, else back to Select (`editor.cancel()`) | Keyboard |
| ⌫ and ⌦ | Deletes the selection, as Edit › Delete does | Selection |
| ↩ (and ⌤) | Edits the only selected shape | Selection |
| ⌘A | Selects everything, as Edit › Select All does | Selection |
| ⌘[ | Goes back to what was selected before, as Go › Back does (while there's somewhere to go) | Selection |
| ⌘X, ⌘C, ⌘V | Cuts, copies and pastes shapes, as Edit › Cut, Copy and Paste do | Clipboard |
| ⌘Z, ⇧⌘Z | Undoes and redoes, as Edit › Undo and Redo do (held, again and again) | Keyboard, for the core's `.undo` and `.redo` |

- **A chord** (`KeyChord`) is a key and the modifiers held with it. A character literal is a key
  alone (`"v"`), and a letter's case doesn't count; `KeyChord("a", .command)` is ⌘A, and the keys
  that type no character have names (`.escape`, `.return`, `.enter`, `.delete`, `.deleteForward`,
  `.tab`, `.space`, the arrows). It describes itself as menus do: `⇧⌘G`, `⌫`.
- **One shortcut per chord.** Two plugins wanting one key are `RegistryError.conflict`
  (`keyboard and clash both claim shortcut H in KeyboardShortcuts`), and a key for a tool no plugin
  registers, or a command none claims, is `invalid`. A plugin with a key imports Keyboard, so a plugin list with Selection or
  any shipped tool needs `KeyboardPlugin()` too (`ownerNotInstalled` otherwise).
- **⇧ counts when a chord asks for it.** A key held with ⇧ answers its ⇧ chord if one is
  registered, and else, where ⇧ may be only what typed it, the chord without ⇧: with ⇧ alone, since
  ⇧ there makes a letter a capital or types a character (V is V with caps lock on, and `"?"` is the
  key that types a question mark), and with ⌘, ⌥ or ⌃ too, for punctuation, a symbol or a digit
  (⌘? is ⇧⌘/ on a US keyboard, and ⌘. is ⇧⌘; on a French one). For a letter, or a key that types
  no character, ⇧ counts: ⇧⌘Z isn't ⌘Z, nor ⇧⌘→ ⌘→.
- **`when`** lets a key pass: it goes on to the next chord it answers, or out of the canvas. **A
  held key** does its thing once; its repeats are the shortcut's all the same (so AppKit doesn't
  beep), and run it again only with `repeats: true`, for a key meant to be held.
- **Commands and menus.** A command (`CanvasCommand`) is what a menu item runs: the canvas forwards
  Edit › Delete and Edit › Select All with `editor.perform`. `registrar.command(.selectAll,
  shortcuts: [KeyChord("a", .command)]) { ... }` claims the command and gives it its key in one
  call, so ⌘A and the menu item do one thing. While a command can't run (its `isEnabled:`, which
  dims its menu item), its keys go on as if there were no shortcut: ⌘[ with nowhere to go back to.
- **A ⌘ key a menu item also has** is the shortcut's while the canvas has the keyboard. AppKit asks
  the key window's views for a key equivalent before the menu bar, and the canvas asks the
  shortcuts (`CanvasView.performKeyEquivalent`), so ⌘A goes through Keyboard like any other key, and
  a plugin that gives a menu's key a meaning on the canvas gets it there. With a field focused, the
  canvas passes, and the menu has it: Edit › Select All selects the field's text.
- **Only on the canvas.** A key reaches the shortcuts while the canvas has the keyboard: typed in a
  note or a panel field, it's text, and a control in the panel that has the keyboard answers its own
  keys. What they do is still the same registered thing: Delete in the table of contents' list runs
  the `.delete` command, as Delete on the canvas and Edit › Delete do, and Escape anywhere in the
  panel gives the keyboard back to the canvas. The menu bar's other key equivalents (⌘S, the View
  menu's zoom) belong to their items and work wherever the keyboard is; with text or a panel's
  control focused, ⌘Z is the menu's, whose Undo is the text's own there and the board's elsewhere.
- **A key no shortcut takes** goes on to AppKit's key bindings, as any view's would. The standard
  actions they send that have a key of their own come back to the shortcuts as that key:
  `deleteBackward:` as ⌫, `deleteForward:` as ⌦, `insertNewline:` as ↩ and `cancelOperation:` as ⎋.
  So ⌃H (an emacs binding for `deleteBackward:`) does what Delete does, and so does a user's own
  key binding for it, or accessibility's cancel. The canvas answers no other action, which goes on
  up the responder chain.
- **Tooltips.** `registry.help(for: tool)` is a tool's label and its key, "Note (N)". The toolbar
  (CanvasUI) can't see Keyboard, so the app hands it `ShippedPlugins.help(for:in:)`.
- **The core's part** is one hook, like the secondary click's: at most one plugin claims key strokes
  (`registrar.keyStrokes { editor, stroke in ... }`, returning whether it took the key). `CanvasView`
  hands every key it gets to the editor (`editor.keyDown`, host API), as a `KeyStroke`: its
  characters as the keyboard's layout types them with no modifier but ⇧, the modifiers held, and
  whether it's a repeat. Without a claim, no key does anything on the canvas. Keyboard gathers each
  editor's shortcuts by chord once, in a service (`KeyboardState`), since the registry is frozen.

## The detail panel

The detail panel is the inspector beside the canvas, after Keynote's: it shows the selected shape
and edits its properties. It's a horizontal ([`Sources/DetailPanel`](../Sources/DetailPanel)) like
any other. It declares two extension points, kinds and other plugins contribute to them, and the
core has never heard of it.

### Anatomy and conventions

```
┌─ inspector column: 248 to 340 pt, 260 ideal ────────┐
│ ‹ ☑  Write the spec                                 │ header: back, symbol, title (here a
│      Done · 2 of 5 · Due Sep 30                     │   field: the task is renamed there)
│ ⟦ Task ⟧  Checklist  Style  Arrange  Issues         │ tab strip, hidden with one tab
├─────────────────────────────────────────────────────┤
│     Status  [ ● Done               ⌄ ]              │ a tab's first section: untitled,
│   Priority  [ Low | Med | High ]                    │   never collapses; rows: label
│                                                     │   column, then control
├─────────────────────────────────────────────────────┤
│ › Notes                                             │ a titled section collapses,
├─────────────────────────────────────────────────────┤
│ ⌄ Schedule                                          │   and may have one header control
│        Due  ☑ [ 9/30/2026 ]⇅                        │
│   Estimate  [   4 h ]⇅                              │
│  Remaining  0 h                                     │ a read-only row
│                        (scrolls)                    │
├─────────────────────────────────────────────────────┤
│ (footer)                                            │ footer: status lines, on every tab,
└─────────────────────────────────────────────────────┘   hidden when empty (none ship today)
```

The panel owns all of the chrome, and plugins fill it in:

| The panel decides | Plugins provide |
|---|---|
| The header's frame, and its back button (Selection's `goBack`, shown while there's a step back) | The header: a `DetailHeader` (title, subtitle, symbol), or a view built on `DetailHeaderLabel` (Titles' `TitleHeader`) |
| The tab strip, the tab order, and the tab remembered per kind | Which tab each section goes in |
| Section chrome: the header, chevron, header-control slot, insets, dividers, collapsing, and remembered collapse | Section titles, ids and order, and at most one header control per section |
| Scrolling, the footer, and the empty states | The rows in a section, and status lines: the footer's, or a tab's (the Issues tab above, while the task has any) |
| Fonts, control size, the label column and checkbox toggles, all through the environment | |
| Focus: what gives the keyboard back to the canvas | |

With nothing selected the panel shows its overview, a view the host may give it (the app's is
[the table of contents](#the-table-of-contents)), else "No Selection". With several, it shows "N
Shapes" over the kinds selected, then the overview (details are per shape: editing several at once
isn't built). A shape nothing contributes
to (an arrow, today) gets its header, then "No Options". Without `DetailPanelPlugin` installed, the panel says
"No Details". A read-only shape (a [locked](#locking) one) shows its whole panel, but nothing in it
edits the shape: the panel disables its sections' content and header controls, and its header (a
title field), and leaves going back, the tabs and collapsing as they were. It asks the registry
(`registry.isReadOnly(record)`), not the editor, so the panel doesn't read the document.

Sections are stock SwiftUI plus a few primitives, and get the look by following these conventions:

- **Rows.** A labeled control is `LabeledContent("Due") { control }`; the panel lines every label
  up in one 72 pt column and hides the control's own label (its placeholder stays). A read-only
  value is `LabeledContent("Remaining", value: ...)`. A toggle stands alone, drawn as a checkbox
  with its label after it; in a row, it's a bare box.
- **Primitives.** A number is a `DetailNumberField`, and a pair of them (Width and Height) goes in
  `DetailFields`. Multiline text is a `DetailTextArea` (with a `placeholder:` shown while it's
  empty, and an `onCommit:` for text that's acted on once it's done: then Return commits, ⇧↩ is a
  new line, and the keyboard leaving commits too, a turn later if the text view left its window
  with the keyboard, so capture a service in `onCommit` weakly: the board may have gone), code a
  `DetailCodeEditor` (monospaced, typed exactly as keyed: smart quotes and dashes, text
  replacement, autocorrect, spelling, completion, inline predictions, math results and Writing
  Tools off; lines never wrap, so a line's indentation says where it is and line N of an error is
  the Nth on screen, and a long one scrolls sideways; as tall as its lines, from
  `DetailStyle.codeEditorHeight` (a text area's height, so a short text sits in a short box with
  what's said about it close under it) to what the panel shows, less room for its section's title; Tab
  two spaces, Return a new line as indented as the last, one step more after `{` or `[`; ⌘↩ and the
  keyboard leaving call its `onCommit`; `isEditable: false` makes it read-only), a list a
  `DetailList` (empty, it says No Items), a color `DetailSwatches` (named presets, the chosen one
  marked, then the color well; it spans the row, so it goes in a section of its own, not in a
  `LabeledContent`). `.detailUpdating(isUpdating)` marks a text box something else is writing just
  now (a model): read-only, and so dimmed; nothing is drawn over its text. What's writing it says
  so in words where the person is: a status line of a section's own, a `DetailStatusLine`, drawn
  as the footer's (only its symbol takes the tone), with a spinner in the symbol's place, as wide,
  while `isBusy`, and link buttons under it
  (`DetailStatusAction("Retry") { … }`). Put it where it can't be collapsed away from the person
  (the schema card's sync puts it under the side they edited).
  `DetailNumberText` formats and parses numbers with units ("240 pt"), in the user's locale ("2,5 h"
  in German), as the number field does.
- **Sections.** A tab's first section may be untitled; use it for the main properties. Every
  titled section collapses. Titles are one or two nouns in Title Case.
- **Header control.** At most one small control, acting on the whole section (Checklists' menu). A
  switch for one row goes in that row, beside what it governs (the task's Due checkbox).
- **No styling of your own.** No fonts, sizes, padding or backgrounds.
- **Writes** go only through the section's `ShapeBinding`. Sections never see the editor; one that
  shows a plugin's own state about its shape reads that plugin's service, `$x.service(S.self)` (the
  schema card's sync), from a view of its own, so observing it redraws only that view.

### Tabs are types; any plugin adds one

A tab is a type conforming to `DetailTab`. Any module may declare one, and there's no registration
call: a tab shows for a shape when a shown section that applies to the shape names it.

```swift
public enum ChecklistTab {}
extension ChecklistTab: DetailTab {
    public static var title: String { "Checklist" }
    public static var order: Int { 50 }
}
```

Being a type, a tab can't be misspelled, and sharing one means importing the module that declares
it. Tabs sort by `order`, then by first appearance, in these bands:

| Order | Tabs |
|---|---|
| 0 (the default) | A kind's own tabs (Task) |
| 50 | Feature tabs a horizontal brings to the kinds that opt into it (Checklist) |
| 100 | `StyleTab`: appearance, shared by every kind |
| 200 | `ArrangeTab`: position and size, which the panel fills for every box shape |
| 300 | A tab of the shape's state that comes and goes with it (ValidationDetails' `IssuesTab`): last, so the others keep their order |

Use the shared `StyleTab` and `ArrangeTab` rather than near-duplicates. Two tab types with one title
would show as two identical tabs, so they're a registry error (`invalid`, below), whether sections
or status lines name them.

### Contributing: two points and their sugar

| Point | Kind | Holds |
|---|---|---|
| `ShapeDetails` | keyed | A header and sections, one contribution per `details` call. Each section claims (target, tab, id), and a header claims its target, so two plugins adding a Color section to a kind's Style tab, or two headers for one kind, are a `conflict`. A kind's own section and an every-box one may share an id; both show. |
| `DetailStatuses` | list | Status lines, the shape's state rather than its settings, as a `DetailStatusContribution`: where they go (the footer, or a tab) and `@MainActor (AnyShapeRecord, DetailContext) -> [DetailStatus]`. |

Plugins write the sugar, not the points:

| Sugar | For |
|---|---|
| `x.details(header:) { sections }` | This kind's header and sections, inside `registrar.shape { x in ... }`. The header is a view made from the shape's binding ([the header](#the-header)). |
| `registrar.details(P.self, header:) { sections }` | Another plugin's kind, typed as its own (bridges). |
| `registrar.detailsForEveryBox { sections }` | Every shape with a frame, editing the frame. Arrows have none, so they don't get these. |
| `x.details(of: P.self) { sections }`, `registrar.details(of: P.self) { sections }` | An [added property](#added-properties), editing its value: on this kind's shapes that have one, or on every shape that has one. |
| `registrar.detailStatusForEveryShape { shape, context in ... }` | Footer lines for every shape. Return `[]` when there's nothing to say. |
| `registrar.detailStatusForEveryShape(in: SomeTab.self) { shape, context in ... }` | Lines in a tab for every shape. The tab shows while the shape has lines there, above its sections if it has any. |

`details` always takes its trailing builder, so a header alone is `details(header: ...) {}`. A
section is a `DetailSection` naming its tab, with an optional title, an `id` (the title by
default, or "main"), an optional `when` that hides it (and a tab it leaves empty) for some values,
its content, and an optional header control (`accessory:`). `when` runs on every render, so keep it
cheap. The panel's own contribution is Arrange, for every box
([`DetailPanelPlugin`](../Sources/DetailPanel/DetailPanelPlugin.swift)):

```swift
registrar.service { DetailPanelState(editor: $0) }
registrar.detailsForEveryBox {
    DetailSection("Size", in: ArrangeTab.self) { $frame in
        DetailFields {
            DetailNumberField("Width", value: $frame.size.width, unit: "pt", in: 1...100_000)
            DetailNumberField("Height", value: $frame.size.height, unit: "pt", in: 1...100_000)
        }
    }
    DetailSection("Position", in: ArrangeTab.self) { $frame in ... }
}
```

How it resolves, per shape:

| What | Order |
|---|---|
| Sections in a tab | The kind's own (from its vertical, a horizontal it opts into, or a bridge), in plugin order and builder order; then every kind's (every-box sections, and those over an added property on every shape that has it), in plugin order. |
| Tabs | By `order`, then first appearance over the same sequence, then status lines'. A tab with no shown section and no status line is dropped. |
| Status lines, the footer's and each tab's | The kind's, then every kind's, each in plugin order. |
| Header | The kind's own; else the label and symbol of the tool that places the kind; else the kind's name. A header without a symbol takes the tool's. |

`DetailPanelState` (`editor.detailPanel`) gathers each kind's contributions once, since the
registry is frozen, and resolves the selected shape's layout (running `when` and the headers) as
it's shown. It also remembers, per editor and in memory, the tab last chosen for each kind and the
collapsed sections. A collapsed every-box section collapses for every kind; a kind's own, for
that kind only.

### The header

A kind's header is a view it makes from its shape's binding, as a section's content is:

```swift
gadget.details(header: { $gadget in DetailHeader(gadget.name, subtitle: gadget.mode.rawValue) }) { ... }
```

- **`DetailHeader`** is the stock header: a symbol, then a title on one line over a subtitle, as the
  panel lays them out. A kind without a header of its own gets one with its tool's label.
- **A header of the kind's own** builds on `DetailHeaderLabel(subtitle:systemImage:) { title }`,
  that layout with any view as its title, so it looks like every other header.
  `DetailHeaderField(text, placeholder:)` is the title as a field, for a header that renames its
  shape in place: borderless, in the header's font, writing as you type (as the panel's text
  fields do), with the kind's name as its placeholder by default. Return, like Escape anywhere in
  the panel, gives the keyboard back to the canvas. `isEditable: false` shows the title as text
  in its place, at full strength, for a title that can't be written just now; `disabled` dims the
  field, for a while something else writes it.
- **A header without a symbol** shows its kind's: the panel hands a header view its kind's name
  and symbol through the environment, as the table of contents hands a row its symbol.
- **Headless**, `layout.header` is the header when it's a `DetailHeader` (with its kind's symbol
  if it has none), and `layout.header(as: TitleHeader.self)` reads back a header of another type,
  as the table of contents reads rows back as `ContentsLabel`s.

### Renaming in the header: TitleHeader

Titles publishes the header for a kind whose shapes are renamed in the panel, so no kind writes
its own ([TitleHeader.swift](../Sources/Titles/TitleHeader.swift)). The kind puts it in its slot:

```swift
note.details(header: { $note in TitleHeader($note) }) {}
task.details(header: { $task in TitleHeader($task, placeholder: "Untitled Task", subtitle: $task.shape.summary) }) { ... }
```

It's a `DetailHeaderLabel` whose title is a `DetailHeaderField`. Each keystroke renames the shape
(one transaction), so its pill and its row in the table of contents follow as you type. Given the
shape, it renames the title Titles keeps (`$note[TitleProperty.self]`, which the kind must opt
into with `note.title()`: a debug build stops at one that doesn't): clearing the field, or leaving
only spaces in it, sets nil, since Titles keeps no blank title; anything else is kept as typed, and
one past 80 characters is kept, and warned about. A title derived from what the kind keeps is
renamed where it comes from, given that binding instead: a `String?`, or a `String` blank while
untitled (`TitleHeader($card.text)`). While there's no title it shows its placeholder,
dimmed: the kind's name ("Note"), unless the kind gives one ("Untitled Task"). `isEnabled: false`
dims it while something else writes the title (a schema card's model); `isRenamable: false` shows
it as text, at full strength, while it can't be written at all (a schema card's text that isn't a
JSON object). A derived title that can't ever be renamed (an ellipse's size) isn't; a kind with one
keeps a `DetailHeader`, if it has a header at all.

Opting into titles doesn't place it: the header is the kind's, which may want its own subtitle,
placeholder or symbol, or no rename in the panel at all.

### A horizontal's feature tab: Checklists

The pattern the panel is built for: a horizontal exposes a way for individual shapes to opt into a
feature, and the feature shows up as a tab in the panel. Opting in is one line on the kind, and the
tab comes with it, on exactly the kinds that opt in.

[Checklists](../Sources/Checklists/Checklists.swift) gives any kind a checklist, an
[added property](#added-properties) of each of its shapes. Checklists owns the property
(`ChecklistProperty`), the item type, its helpers (`doneCount`, `progress`, `setAllDone`,
`removeDone`), the bulk actions (`ChecklistBulkAction`), the tab, and the chip it places on the
canvas (`ChecklistChip`, an [adornment](#adornments)). `ChecklistsPlugin` declares the property
(`registrar.declare(ChecklistProperty.self)`) and places the chip on every shape whose kind shows
it, and its sugar opts the kind in, then contributes to its own point and to the panel's, from the
same `ShapeRegistrar`, fully typed:

```swift
/// The extension point: which kinds have a checklist, and how they show it. At most one per kind.
public enum ShapeChecklists: KeyedExtensionPoint {
    public typealias Contribution = ChecklistContribution    // whether the canvas shows the chip
    public static var owner: PluginID { .checklists }
    public static func uniqueKeys(of _: ChecklistContribution, for target: ShapeTarget) -> [AnyHashable] { [target] }
}

extension ShapeRegistrar {
    /// Gives this kind's shapes a checklist (`ChecklistProperty`, in the kind's schema as
    /// `checklist`): a Checklist tab in the detail panel, the bulk actions that apply in its context
    /// menu, and (unless `badge` is false, for kinds that draw their own) a small done/total chip on
    /// the canvas (`ChecklistChip`). `note.checklist()`.
    public mutating func checklist(badge: Bool = true) {
        optIn(to: ChecklistProperty.self)
        contribute(ChecklistContribution(showsBadge: badge), to: ShapeChecklists.self)
        details(of: ChecklistProperty.self) {
            DetailSection("Items", in: ChecklistTab.self) { $items in
                ChecklistRows(items: $items[dynamicMember: \.self])
            } accessory: { $items in
                ChecklistMenu(items: $items)
            }
            DetailSection("Progress", in: ChecklistTab.self, when: { !$0.isEmpty }) { items in
                ChecklistProgress(items: items.wrappedValue)
            }
        }
        // ... and the bulk actions, in the context menu (below)
    }
}
```

- **Opting in.** Sticky notes write `note.checklist()`, task cards `task.checklist(badge: false)`,
  since a card draws its own list. Neither kind declares anything: every note and every task has a
  checklist, empty until someone adds an item, and reads it as `shape[ChecklistProperty.self]`
  where it shows it (a note's row, a task's summary).
- **The chip** is Checklists' to place, not the kind's: `ChecklistsPlugin` puts it on every shape
  of the kinds that opted in without `badge: false` (its `where` reads `ShapeChecklists`), and it
  shows only on a shape with items, "☑ 2/5" on the top-right corner, green once every item is done:

  ```swift
  registrar.adornmentForEveryShape(ChecklistChip.self, where: { $0.registry.showsChecklistChip($0.kind) }) { shape, _ in
      guard let items = shape[ChecklistProperty.self], let tally = items.tally else { return nil }
      return AdornmentLabel("☑ \(tally)", tone: items.doneCount == items.count ? .success : .neutral)
  }
  ```
- **The graph.** StickyNotes imports Checklists and never ContextMenus, yet gets menu items. The
  requirement shows up at startup instead: a list with StickyNotes but without `ChecklistsPlugin`,
  `DetailPanelPlugin` or `ContextMenusPlugin` is `ownerNotInstalled`, naming the missing one, and
  so is a list with `ChecklistsPlugin` but without `AdornmentsPlugin`, which lays out its chip.
- **The property is the contract.** The sections are over the property's value, not the kind's
  props: each gets a `ShapeBinding<[ChecklistItem]>`, and `$items[dynamicMember: \.self]` is a
  `Binding` to the list that writes only that value, on that shape. The Items header's menu is a
  `ForEach` over `ChecklistBulkAction` (Check All, Uncheck All, Remove Checked), each disabled
  unless `isEnabled(for:)` and applied in one `update`: `$items.update { action.apply(to: &$0) }`.
  The rules live on the enum, so tests check them without opening the menu.

Another feature in this pattern has the same parts: its data type, an added property holding it,
declared by the horizontal; a keyed point for whatever else it needs per kind (Checklists' chip
flag); a tab type at order 50 (and a menu group, if it has actions); sugar that opts the kind into
the property and contributes sections and items over its value; and whatever consumes it (a lookup
on `Registry`, an adornment).

### A tab of status lines, from a bridge: ValidationDetails

Status lines are a shape's state, not its settings: at the foot of the panel, on every tab, or in
a tab of their own, which shows only while the shape has lines there.
[ValidationDetails](../Sources/ValidationDetails/ValidationDetails.swift) lists each shape's
validation issues in an Issues tab. It's a bridge between two horizontals, and its imports are
the only edge between them:

```swift
import Canvas
import DetailPanel
import Validation

public struct ValidationDetailsPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "validation-details" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.detailStatusForEveryShape(in: IssuesTab.self) { shape, context in
            (context.service(ValidationEngine.self)?.result(for: shape.id)?.worstFirst ?? [])
                .map { DetailStatus($0.message, tone: DetailStatus.Tone($0.severity)) }
        }
    }
}

/// A shape's validation issues. It comes and goes with them, so it trails every other tab.
public enum IssuesTab {}
extension IssuesTab: DetailTab {
    public static var title: String { "Issues" }
    public static var order: Int { 300 }
}
```

Issues come worst first (errors, then warnings, each in the rules' order), each line its
severity's symbol, red or orange, then its message. The tab is at order 300, after Style and
Arrange, so the other tabs keep their order as it comes and goes, though not their width: the
strip shares its width among its tabs, and a kind with one tab (a rectangle's Arrange) gains a
strip with it. The tab is remembered per kind, as any is: once someone chooses Issues, the next
shape of that kind with issues opens on it, and one without opens on its first tab. A tab's lines
lead it, above any sections another plugin puts there. A status contributor reads services through
`DetailContext`, read-only. Status lines are re-read on every document change, so read a cached
service, as this one reads validation's engine. Without Validation installed there's no engine,
no lines, and no tab. So an empty sticky note has an Issues tab that says "This note is empty.",
and StickyNotes didn't change.

### The full showcase: TaskCards

[TaskCards](../Sources/TaskCards) is a vertical whose panel is its only editor: task cards aren't
`Editable`. Press T to place one. Every field in the panel changes how the card draws.

```swift
registrar.shape(TaskCardDefinition()) { task in
    let place = task.placement(size: TaskStyle.size) { TaskCard() }.setting(TitleProperty.self, to: "New Task")
    task.tool(label: "Task", systemImage: "checklist", shortcut: "t", placing: place)
    task.validate { shape, _ in shape.issues }
    task.taskPanel()                                  // below
    task.checklist(badge: false)                      // a checklist, and its tab, without the chip
    task.title(pill: false)                           // a title (its row's name), without the pill
}
```

A task's title is Titles' (`shape.title` on its record reads it), which the card draws, and which
must be there: `shape.issues` makes an untitled task an error, beside the warning Titles' schema
gives a title that's too long.

`taskPanel()` (in [TaskCardPanel.swift](../Sources/TaskCards/TaskCardPanel.swift)) is one
`details` call, here abbreviated:

```swift
details(header: { $task in TitleHeader($task, placeholder: "Untitled Task", subtitle: $task.shape.summary) }) {
    DetailSection(in: TaskTab.self) { $task in
        LabeledContent("Status") { StatusPicker(status: $task.status) }
        LabeledContent("Priority") { ... }
    }
    DetailSection("Notes", in: TaskTab.self) { $task in
        DetailTextArea($task.notes)
    }
    DetailSection("Schedule", in: TaskTab.self) { $task in
        LabeledContent("Due") {
            HStack {
                Toggle("Has due date", isOn: $task.hasDue)
                if task.hasDue {
                    DatePicker("Due", selection: $task.dueDate, displayedComponents: .date).datePickerStyle(.stepperField)
                } else {
                    Text("None").foregroundStyle(.secondary)
                }
            }
        }
        LabeledContent("Estimate") { DetailNumberField(value: $task.estimate, unit: "h", in: 0...999, step: 0.5) }
        LabeledContent("Remaining", value: DetailNumberText.format($task.shape.remaining, unit: "h"))
    }
    DetailSection("Color", in: StyleTab.self) { $task in ... }
    DetailSection("On the Card", in: StyleTab.self) { $task in ... }
}
```

The summary and the hours remaining count the task's checklist, which isn't in its props: they're
read from `$task.shape`, the shape the panel drew, with its added values. The title isn't in its
props either: the header binds it (`$task[TitleProperty.self]`).

Five plugins fill one card's panel:

| Part | Holds | From |
|---|---|---|
| Header | the title, renamed in place ("Untitled Task", dimmed, while there's none), over a summary: "Done · 2 of 5 · Due Sep 30" | TaskCards, with Titles' `TitleHeader` |
| Task (0) | an untitled section (Status, Priority), Notes, Schedule | TaskCards |
| Checklist (50) | Items, and Progress once there are items | Checklists, through `task.checklist` |
| Style (100) | Color, On the Card | TaskCards |
| Arrange (200) | Size, Position | DetailPanel, for every box |
| Issues (300) | the task's issues, worst first ("A task needs a title."), while it has any | ValidationDetails |

### Reading and writing: `ShapeBinding`

A section's content closure gets a `ShapeBinding`. Take it as a `$` parameter, as with
`ForEach($items) { $item in }`:

- **`task.notes` reads the snapshot** the panel drew with. Nothing in a section reads
  `editor.document`, so a section isn't rebuilt when other shapes change.
- **`$task.notes` is a `Binding`.** Each set writes that one key path into the *live* shape, in its
  own `editor.transact`. A move made after the snapshot survives a rename, two writes in one action
  both land, and setting the value the shape already has commits nothing. After a write, the
  binding reads what it made of the shape, before the panel draws again, as SwiftUI expects of a
  binding: a text field that takes Return (or Escape) straight after a keystroke would otherwise
  put the text from before back.
- **Writes go to the shape the binding was made for**, never to whatever is selected by the time
  they happen. A write to a shape that's gone does nothing.
- **Read-modify-write goes in `update`**: `$items.update { action.apply(to: &$0) }` (Checklists'
  bulk actions) applies the change to the live value, in one transaction.
- **Bind the narrowest key path.** A collection's binding (`$items[dynamicMember: \.self]`, and the
  row bindings `ForEach` derives from it) writes the whole collection, rebuilt from what the binding read (the
  snapshot, or its last write). Use `update` for list operations.
- **`$task.shape` is the whole shape** the snapshot came from, a `ShapeRecord<TaskCard>`: its props
  and its [added properties](#added-properties)' values, for what a section or a header shows from
  both (`$task.shape.summary`, `$task.shape[ChecklistProperty.self]`). It only reads; writes go
  through the binding.
- **`$task[TitleProperty.self]` binds an added property** of the shape, a `Binding<String?>`: nil
  while the shape has none, each write one transaction on the live shape, nil removing it (for a
  property whose default is nil). It reads back its last write, as the key paths' bindings do.
  `TitleHeader($task)` renames through it.
- **Three kinds of binding, three write paths.** A kind's own sections get its props, typed, only
  from contributing for the kind: from its own plugin, a horizontal it opts into, or a bridge.
  Every-box sections get a `ShapeBinding<CGRect>`, the frame, whatever the kind. Sections over an
  added property get its value (`ShapeBinding<[ChecklistItem]>`), on the shapes that have one. Any
  of them binds an added property of its shape by its type (`$x[P.self]`), through the whole
  record: nil, and writes dropped, on a kind that doesn't opt into it (`$x.holds(P.self)` says
  whether it does). The added properties' bindings one `$x` makes read back the last write through
  any of them, until the panel redraws.
- **Other forms.** A plain parameter works too (`items.wrappedValue` is the snapshot, as in
  Checklists' Progress), and a larger section can be a View declaring
  `@ShapeBinding var items: [ChecklistItem]`, passed `$items` (Checklists' `ChecklistMenu`).
- **Undo steps.** A write is named for its section, "Change" and the section's title ("Undo Change
  Color"); in the header, or a section without a title, "Change" and the kind's name ("Undo Change
  Task", the label of the tool that places it). Writes to one field of one shape, one after
  another, are one step, however many keystrokes (a field typed into, a slider or a color
  dragged): a run under the key `[shape, key path]` (for the frame's too), or `[shape, property
  key]` for an added property's binding and `$x[P.self]`, until anything else happens: a write to
  another field, any other change, an action, or the host sealing the run as the user clicks or
  types somewhere else (`editor.undoHistory.seal()`, which the board's window calls). Each `update`
  is a step of its own (Checklists' bulk actions). A field whose writes go through a method of the
  value, because more follows from them, runs as the field does with `update(\.field) { ... }`:
  the schema card's JSON Schema, typed, is `$card.update(\.schema) { $0.setSchema(text) }` (which
  fits the card to it), and its header's rename `update(\.schema) { $0.setTitle(name) }`, so what's
  typed is one step, as `$card.prompt`'s is.

Tests and tools reach the same bindings with `editor.shapeBinding(id, as: TaskCard.self)`,
`editor.frameBinding(id)` and `editor.propertyBinding(id, ChecklistProperty.self)`.

Two compiler rules come with this:

- **Keep the sugar's closure types unannotated.** Annotated `@MainActor`, Swift 6.3 compiles a
  `$`-parameter body as nonisolated, and every view initializer in it fails.
- **Never name `Transaction` in a file that imports SwiftUI.** SwiftUI has its own `Transaction`,
  and its `Canvas` view shadows the core module, so `Canvas.Transaction` doesn't resolve either.
  Let closure inference type `$0`.

When each control commits:

| Control | Commits |
|---|---|
| Text fields, `DetailTextArea`, `DetailCodeEditor`, `DetailHeaderField` | On every keystroke, so the canvas follows as you type. With `onCommit:`, a text area also says when it's done (Return, the keyboard leaving), and a code editor too (⌘↩, the keyboard leaving) |
| Pickers, toggles, steppers, dates, swatches, the color well, list add, remove, move and edit | On change |
| `DetailNumberField` | A draft: on Return, Tab, leaving the field, or the field going away, in one transaction, clamped to its range. Escape drops the draft. Stepping writes at once. A draft lands on its own shape even if the selection moves first. |

### Focus and hosting

- **Typing in the panel never triggers a shortcut.** Keyboard answers only keys typed on the
  canvas, so "n" typed into a title is text, and Delete and Return in a panel field never delete or
  edit the selected shape.
- **The keyboard goes back to the canvas** on a click on the canvas; on Escape in the panel, which
  drops any number draft first; and on its own when the panel removes the control that had the
  keyboard (switching tabs, collapsing its section, a `when` hiding it, or a new selection), or is
  hidden with it (View › Hide Inspector, which hides the panel without removing it).
  Otherwise the keyboard would land on the window, and shortcuts would stop. Collapsing an
  unrelated section leaves the field focused.
- **Inside the panel**, Tab moves between text fields (a `DetailTextArea` takes Tab as text, a
  `DetailCodeEditor` as two spaces), and Return commits a number and keeps the field; in the header's title field (`DetailHeaderField`),
  Return is done renaming, and gives the keyboard back to the canvas. Checkboxes don't take the
  keyboard (the macOS default without Full Keyboard Access); a pop-up, segmented control or stepper
  that has it keeps
  shortcuts from the canvas until Escape.
- **Zoom** (⌘=, ⌘- and ⌘0) works whatever has the keyboard: the app's menu commands reach the
  window's canvas through `CanvasFocus`, not the responder chain. So does Go › Back (⌘[), which
  the board's window controller answers.

The panel can't give the keyboard to the canvas itself (it can't import CanvasUI), so the host
passes `onExit`. `CanvasFocus` (CanvasUI) is the handle: `CanvasRepresentable(editor:focus:)` fills
it, and `take()` makes the canvas its window's first responder.

The app places the panel; the core and CanvasUI know nothing of it. Composition, which decides what
ships, hands the app the view:

```swift
/// The detail panel, for the app to place beside the canvas. It follows the editor's selection;
/// `onExit` must give the keyboard back to the canvas.
public static func detailPanel(editor: CanvasEditor, onExit: @escaping @MainActor () -> Void) -> some View {
    DetailPanelView(editor: editor, onExit: onExit)
}
```

and [the app](../Sources/InfiniteCanvas/InfiniteCanvasApp.swift) puts it in an `.inspector`, which
brings resizing, collapsing in narrow windows, and View › Show Inspector (⌃⌘I) with
`InspectorCommands`:

```swift
CanvasRepresentable(editor: editor, focus: canvasFocus)
    .focusedSceneValue(\.canvasFocus, canvasFocus)
    .inspector(isPresented: $showsDetails) {
        ShippedPlugins.detailPanel(editor: editor, onExit: canvasFocus.take)
    }
```

### Performance

The document changes on every drag event, so the panel does little per change. It re-reads the
selected shape and its status lines, and rebuilds the shape's panel only if either changed;
dragging another shape costs one comparison. A section is rebuilt only when its own shape changes.
Only the current tab is built, a collapsed section's content isn't, and each kind's contributions
are gathered once.
For your part: sections read only their binding, `when` and status lines stay cheap, and anything
heavy goes in a service, kept per shape and redone for the shapes each commit's change set names
(`documentDidChange`), as `ValidationEngine` does.

## Context menus

A right-click on a shape (or a Control-click) opens a menu of what can be done to it. It's a
horizontal ([`Sources/ContextMenus`](../Sources/ContextMenus)) like the detail panel: it declares one
extension point, kinds and other plugins fill it, and the core only passes the click along. A
right-click on a task card with one of its three items checked:

```
┌─────────────────────────┐
│ Status                ▸ │  the kind's own (TaskCards): a submenu, ✓ by the task's status
├─────────────────────────┤
│ Check All               │  a feature's (Checklists, through task.checklist): only the
│ Uncheck All             │    actions with something to do
│ Remove Checked          │
├─────────────────────────┤
│ Cut                     │  the canvas's (Clipboard): Paste once there's something to paste
│ Copy                    │
│ Paste                   │
├─────────────────────────┤
│ Arrange               ▸ │  every shape's (Reordering): Bring to Front, Bring Forward,
├─────────────────────────┤    Send Backward, Send to Back
│ Lock                    │  the canvas's (Locking): Unlock once every shape it's for is locked
└─────────────────────────┘
```

A shape nothing offers anything has no menu: the right-click does nothing. As shipped, every
shape has Lock (or Unlock), and every copyable shape Cut and Copy, items for the canvas, which are
in every menu with shapes; an arrow's menu is those alone, since Arrange leaves it out. On empty
canvas the menu is the canvas's items that apply there alone: Paste, once there's something to
paste.

### Contributing

| Sugar | For |
|---|---|
| `x.contextMenu { items }` | This kind's items, inside `registrar.shape { x in ... }`. A horizontal's opt-in sugar calls it too. |
| `registrar.contextMenu(P.self) { items }` | Another plugin's kind, typed as its own (bridges). |
| `x.contextMenu(of: P.self) { items }`, `registrar.contextMenu(of: P.self) { items }` | An [added property](#added-properties), over its value: on this kind's shapes that have one, or on every shape that has one. |
| `registrar.contextMenuForEveryShape(where:) { items }` | Every shape, over `AnyShapeRecord`. `where:` picks kinds by their definition, and so by capability (`{ !($0 is any PaintOrderAnchored) }`); `when:` picks shapes (`{ $0.box != nil }` for those with a frame). |
| `registrar.contextMenuForCanvas { items }` | Items that aren't one shape's (Cut, Copy, Paste), over the menu's `MenuSubject`: its shapes (none on empty canvas) and the editor. In every menu, after the shapes' own in their groups' order, and alone on empty canvas. Each is asked once per menu, not per shape. |

TaskCards' own, in [TaskCardMenu.swift](../Sources/TaskCards/TaskCardMenu.swift):

```swift
task.contextMenu {
    Submenu("Status") {
        for status in TaskStatus.allCases {
            MenuItem(status.label, isChecked: { $0.status == status }) { $0.status = status }
        }
    }
}
```

- **`MenuItem(title, in:, id:, when:, isEnabled:, isChecked:) { edit }`** edits each shape it's for
  on the live value, all of them in one transaction, as the panel's `update` does. For what editing
  props can't do (reordering, deleting, selecting), the other form, `{ ids, editor in ... }`, gets
  the shapes, in selection order, and the editor, and changes the document with `editor.transact`.
  Whatever an item does, over however many shapes and transactions, is one undo step, named by its
  title ("Undo Bring to Front").
- **`when` leaves an item out; `isEnabled` dims it.** A context menu shows only what applies, so
  reach for `when`. `isChecked` checks it (✓ for every shape, – for some). An item for the canvas
  asks these of its `MenuSubject`, so it can depend on more than a shape (Clipboard's Paste is
  `when: { $0.editor.canPaste }`), and takes the `perform` form, which gets the subject's shapes.
- **`Submenu(title) { items }`** shows when any of its items does.
- **Groups are types**, like tabs: a separator falls between groups, which sort by `order`, then by
  first appearance, in the tabs' bands. An item names its group with `in:`; the default is
  `ShapeMenuGroup`.

  | Order | Groups |
  |---|---|
  | 0 (the default) | A kind's own items (`ShapeMenuGroup`) |
  | 50 | A horizontal's feature, on the kinds that opt in (`ChecklistMenuGroup`) |
  | 100 and up | Shared by every kind (`ClipboardMenuGroup`, 100; `ReorderMenuGroup`, 200; `LockMenuGroup`, 300) |

- **Keyed.** Each item claims its target, group and `id` (the title by default), and an item in a
  submenu its path, so two plugins adding one item to a kind are a `conflict`
  ("sticky-note Check All"), and so are two for every shape. A kind's own item replaces an
  every-shape one with the same group and id.

### A feature that comes with menu items: Checklists

The pattern of the detail panel's feature tabs, again. Checklists' opt-in sugar contributes to its
own point, the panel's, and this one, so `note.checklist()` brings the Checklist tab and the bulk
actions, each shown only where it has something to do. The items are over the property's value, the
list, as the sections are:

```swift
public enum ChecklistMenuGroup {}
extension ChecklistMenuGroup: MenuGroup {
    public static var order: Int { 50 }
}

// In ShapeRegistrar.checklist(badge:), after `details(of:) { ... }`:
contextMenu(of: ChecklistProperty.self) {
    for action in ChecklistBulkAction.allCases {
        MenuItem(action.title, in: ChecklistMenuGroup.self, when: { action.isEnabled(for: $0) }) { action.apply(to: &$0) }
    }
}
```

A future horizontal does the same inside its own sugar: its property, its point, its tab, its menu
items, one line on the kind. The edge comes with it: Checklists imports ContextMenus, so a list with
Checklists needs `ContextMenusPlugin` too. A feature whose menu items should be optional puts them
in a bridge instead.

### Every shape: Reordering

[`Examples/Reordering`](../Examples/Reordering/Reordering.swift) gives every shape an Arrange
submenu, as in Keynote and tldraw, in a group of its own after the rest. It picks kinds by
capability: one painted by anchor (an arrow, drawn just above the shapes it joins) is left out,
since document order doesn't decide where it's drawn. A line, which has no frame, is in.

```swift
registrar.contextMenuForEveryShape(where: { !($0 is any PaintOrderAnchored) }) {
    Submenu("Arrange", in: ReorderMenuGroup.self) {
        MenuItem("Bring to Front") { ids, editor in
            let ordered = backToFront(ids, in: editor.document)
            editor.transact { transaction in
                for id in ordered { transaction.bringToFront(id) }
            }
        }
        MenuItem("Bring Forward") { ids, editor in step(ids, forward: true, in: editor) }
        MenuItem("Send Backward") { ids, editor in step(ids, forward: false, in: editor) }
        MenuItem("Send to Back") { ...  }
    }
}
```

Bring Forward and Send Backward are tldraw's: each shape moves just past the nearest shape that
overlaps it, in that direction (`transaction.move(id, above: next)`), since moving past one it
doesn't overlap would change nothing to see. With several selected, they keep their order among
themselves, and one with nothing to pass stays.

### What a right-click does

The menu is for the selection, as in Keynote and tldraw.

| Right-click | Does |
|---|---|
| On a shape that isn't selected | The menu is for that shape, which becomes the selection. |
| On a selected shape, or on empty space inside a multi-selection's box | The menu is for the whole selection, which stays. |
| On the rest of the canvas | The canvas's items alone (Paste); the selection stays. |
| Where nothing applies | Nothing: no menu, and the selection and any editing stay. That's a kind nothing contributes to, items all left out by `when`, or empty canvas with no items for the canvas that apply. |
| During a press | Nothing. |

The select tool's hit rule finds the shape, so unselectable shapes are seen through. Opening a menu
ends editing. A right-click opens the menu in any tool; a Control-click only in the select tool,
since other tools may read ⌃ as a modifier.

With several shapes, an item shows when every one of them shows it: the same group and id, whichever
plugin contributed it for each kind, so a note and a task selected together share Check All. It's
enabled when it is for any of them, and runs on those: each kind's own `edit`, all in one
transaction, then each contribution's `perform` once, with its shapes. It's checked (✓) when every
shape checks it and mixed (–) when some do; a kind whose item has no `isChecked` counts as
unchecked. A submenu holds what its items resolve to. In a group, a kind's own items come first,
then every shape's, each in plugin and builder order, then the canvas's. A shape's own item with a
canvas item's group and id takes its place, shown or not, as a kind's own item takes an every-shape
one's.

### The core's part

The core has never heard of context menus. It has one generic hook, like commands: at most one
plugin claims the secondary click (`registrar.menuForSecondaryClick { editor, pointer in ... }`,
returning an `NSMenu` or nil), and ContextMenus does. `CanvasView.menu(for:)`, which AppKit asks on a
right-click and on a Control-click, passes the click to the editor (`editor.menu(for:)`, host API),
which asks that plugin unless a press is under way. AppKit shows what comes back. A Control-click
with no menu then reaches `mouseDown`, a press with `pointer.isControlClick` set, for the tool to
take or ignore. ContextMenus keeps each kind's items, gathered once, in a service,
`ContextMenuState`.

## The table of contents

The table of contents is an outline of the board, one row per shape, in the right-hand panel, as
data-canvas has it: with nothing selected the detail panel shows it for the whole board; with
several, just them, under their header; with one, that shape's details instead. It's a horizontal
([`Sources/TableOfContents`](../Sources/TableOfContents)) with data-canvas's contract (its TOC
card providers): each kind says how its shapes appear, and which shapes are listed and under what.
It doesn't look like data-canvas's, though: it's a Mac source list, a SwiftUI `List` with the
system's rows, selection, disclosure triangles and keyboard.

```
┌─ the panel, with nothing selected ──┐
│ Board                               │ header: "Selection", with Show All, when filtered
│ ▾ ▤ Double-click empty space to a…  │ a note: its text, on one line
│     ↗ Arrow                         │   an arrow, under the shape it starts from
│   ▤ Shopping list              1/2  │ a note's checklist tally
│   ▤ Groceries                       │ a titled note: its title (Titles), not its text
│   ◐ Write the spec             1/3  │ a task: its status as a symbol, in the pill's color
│   ○ Untitled Task                 ● │   a blank title shows the placeholder, dimmed; the dot, red: its error (ValidationContents)
│   ▭ Rectangle                       │ a kind with no row: its tool's label and symbol
│   ◯ Ellipse, 200 × 140              │   or its title, here EllipseTitles' derived one
│   ↗ Arrow                           │ an arrow that starts on nothing, at the top
└─────────────────────────────────────┘
```

### A kind's row

StickyNotes' row, in full ([NoteRow.swift](../Sources/StickyNotes/NoteRow.swift)):

```swift
note.contentsRow { note in
    ContentsLabel(note.props.text, placeholder: "Empty Note", color: .yellow, badge: note[ChecklistProperty.self]?.tally)
}
```

- **The row is a view the kind builds**, usually a `ContentsLabel`: a title on one line (each run of
  whitespace folds into a space), a placeholder shown dimmed when the title is blank, an SF Symbol
  (the placing tool's, unless the row gives one) with an optional color, and a badge of a few
  characters at the trailing end ("2/5", "Sep 30"). The list owns everything around it: row
  height, indentation, disclosure triangles, selection, the header. Any view works, but
  `ContentsLabel` is what keeps rows from different plugins alike; use it unless a row really needs
  something else.
- **A row reads only its shape**, as `when`, `nestedUnder` and `contentsTitle` do, unless it names,
  with `affected`, the shapes whose rows a commit may change ([below](#rows-read-from-more-than-their-shape)). The table of
  contents keeps each shape's row, and where it's listed, from one commit to the next, and redoes
  only those of the shapes the commit's change set names (and the rows nested under a shape that
  came or went). So dragging a shape costs its own row, however big the board: well under a
  millisecond at 10,000 shapes, every one listed. (Plus the marks of the shapes whose marks a
  drag may change, when a mark reads other shapes: [marks](#marks-validationcontents).)
- **`when`** lists only some of a kind's shapes: `contentsRow(when: { $0.props.isBound }) { ... }`.
- **`nestedUnder`** names the shape a row goes under. It holds only while that shape is listed
  too, so a selection of just the child still shows it, at the top. Rows nest as deep as their
  shapes do, collapsed under a disclosure triangle; a loop keeps the later shape at the top. Arrows
  nest under the shape they start from, as data-canvas's edges do under their start node. Once
  shapes can contain shapes, a shape's container will be the default.
- **Without a row**, a kind is listed by the label and symbol of the tool that places it ("Arrow",
  "Ellipse"), else by its kind, the fallback the detail panel's header uses. A kind can keep that
  row and still say where it's listed and what it nests under, as Arrows does:

  ```swift
  arrow.contentsRow(nestedUnder: { $0.props.start.binding?.shapeID })
  ```

  `registrar.contentsRow(OtherKind.self) { ... }` gives another plugin's kind a row (bridges). A
  kind has at most one row: two are a `conflict`.
- **A name from another plugin.** `x.contentsTitle { ... }` (the `ContentsTitles` point, or
  `registrar.contentsTitle(OtherKind.self)`) names a kind's rows without replacing them: a name
  that isn't blank takes the place of a `ContentsLabel`'s title, which keeps its symbol, color and
  badge, and nil leaves the row alone. The row a kind without one gets is a `ContentsLabel` too, so
  it takes the name; a row of some other view stays as the kind drew it. Titles names rows this
  way: a note's row is its text until the note has a title. At most one name per kind: two are a
  `conflict`.

| data-canvas's `TocCardProvider` | Here |
|---|---|
| `component` | The view `contentsRow` builds, usually a `ContentsLabel` |
| `filter` | `when:` |
| `getParentShapeId` | `nestedUnder:` |
| `getZoomConfig` | The shape's geometry bounds, with 100 points of margin, for every kind |
| `onClick`, `getGroupChildren` | Not built yet |
| The "other" row (type and id) | The placing tool's label and symbol |

### Rows read from more than their shape

A row may show what other shapes say: a note's row shows its text with the names of the shapes it
mentions, as they're named now, so renaming a shape changes the rows of the notes that mention it
([Mentions](#the-service-mentionstate): `note.contentsRow(affected: MentionRows.affected) { note,
context in ContentsLabel(context.plainText(note.props.text), placeholder: "Empty Note", …) }`). Such a row is built from the shape and a `ContentsContext` (the editor's services, as
a mark's is), returns a `ContentsLabel`, and names, with `affected`, the shapes each commit may
change the rows of without changing them. A ref that shows the name of the shape it refers to,
with a service of its plugin's own that keeps which refs refer to each shape
([AffectedRowTests](../Tests/TableOfContentsTests/AffectedRowTests.swift)):

```swift
ref.contentsRow(affected: { changes, context in
    context.service(RefIndex.self)?.refs(to: changes.shapeIDs) ?? []
}) { ref, context in
    ContentsLabel("→ " + (context.service(RefIndex.self)?.name(of: ref.props.target) ?? "?"))
}
```

- **The rows `affected` names are made again** on the next read, and replaced (so redrawn) only if
  their labels changed: the same title, placeholder, symbol, color and badge keep the row, as a
  mark's `affected` keeps it unless its marks changed. So dragging a shape the refs refer to makes
  their rows again and redraws none of them; renaming it redraws theirs. The shapes a commit
  changes get new rows as always, and a row `affected` names that hasn't been made yet is made
  when it's first listed.
- **`affected` runs on every commit**, whether the list shows or not, so it must cost what the
  commit changed, never the board: a service that keeps who reads what (an index kept up to date
  commit by commit, per shape) answers it. It's asked as the table of contents hears the commit,
  so a service installed before `TableOfContentsPlugin` has heard it already. One installed after
  hasn't, and answers from the commit before: that names the right rows as long as what a row
  reads follows from its own shape, since a commit that changes that changes the shape, whose row
  is made again anyway.
- **Read before it hears of a commit** (by a service that hears first), the table of contents makes
  every kept row of a kind with `affected` again, as it reads every mark again, since only hearing
  of the commit says which it affects. That's rare: the list reads on the next turn.
- **`when` and `nestedUnder` still read only the shape**, and `contentsTitle` still names the row:
  a name that isn't blank takes the place of the label's title (a titled note shows its title).
- `registrar.contentsRow(OtherKind.self, affected:) { shape, context in ... }` is the same for
  another plugin's kind (bridges). The row that reads only its shape keeps its forms,
  `x.contentsRow { ... }` and `x.contentsRow(when:nestedUnder:)`.

### Marks: ValidationContents

A mark is a small dot at the trailing end of a shape's row, from any plugin: a state worth seeing
at a glance down the list. [ValidationContents](../Sources/ValidationContents/ValidationContents.swift),
a bridge between Validation and the table of contents, marks each shape with issues in the color
the canvas outlines it in, red with an error and orange with warnings alone, and the dot's tooltip
lists them, worst first. So the table of contents is where a board's issues are found: look down
the list for dots, and click a row to select its shape and bring it into view, where the panel
shows its Issues tab.

```swift
registrar.contentsMarkForEveryShape(affected: { changes, context in
    context.service(ValidationEngine.self)?.dependents(of: changes.shapeIDs) ?? []
}) { shape, context in
    guard let result = context.service(ValidationEngine.self)?.result(for: shape.id), let worst = result.worst else { return nil }
    return ContentsMark(color: Color(nsColor: worst.color), help: result.worstFirst.map(\.message).joined(separator: "\n"))
}
```

- **A mark is part of its row**, made with it, and made again with it when a commit changes the
  shape. So a commit still costs the rows it changed, and SwiftUI redraws only those. Reading
  marks in the row's view instead would cost the whole board: the list makes every row's view
  whenever it redraws, and a row view that read the document would be asked for again after
  every commit.
- **`affected`** is for a mark read from more than its shape. Given each commit's change set, it
  names the shapes the commit doesn't change whose marks it may. Their marks are read again on
  the next read, and a row is replaced (and redrawn) only if its marks changed, so a shape many
  rules look at costs its dependents' marks when it's dragged, not their rows. Validation's rules
  may look at other shapes (`context.shape(_:)`), and the engine knows whose did
  (`dependents(of:)`): flattening the box a rule checks marks the shape the rule is for. A mark
  read from its shape alone leaves `affected` out. A service that reads the table of contents as
  it hears of a commit, before the table of contents does, gets every row's marks read again,
  since only hearing of the commit says which it affects.
- **Several marks** on one row stand side by side: the kind's, then every kind's, each in plugin
  order (`ContentsMarkContribution`, contributed for a kind, is a kind's own).
- **Headless**, `entry.marks` is a row's marks.

### What's listed, and selecting

- **Rows are in document order**, back to front, like data-canvas's z-ordered outline. Selecting a
  shape doesn't restack it, so rows move only when shapes are restacked (Bring to Front).
- **A shape the board keeps aside has no row**, whatever its kind (one that isn't installed isn't
  listed by its kind's name), since nothing on the canvas sees it
  ([Boards on disk](#boards-on-disk)). A row that names it to nest under stays at the top.
- **Selecting filters the list**, like data-canvas's multi-select summary: select several shapes
  on the canvas and only they are listed, under their header ("2 Shapes") and "Selection"; select
  nothing and the whole board is, under "Board"; select one and the panel shows its details. Show
  All lists the board again without deselecting.
- **A change of what's listed replaces the rows**, so the new scope's come in as one run under the
  header, not around the rows both scopes list (and nested rows start collapsed again). Rows coming
  in at several places at once, the last row among them, make AppKit measure the last row from
  inside measuring the others (a table whose rows size themselves, as a SwiftUI `List`'s do,
  measures new rows a run at a time and resizes itself after each) and log "a reentrant operation
  in its NSTableView delegate", which it says will become an assert. It still logs that when a list
  first shows 200 rows or more (it measures 200 at a time), and when a commit brings rows in at
  several places, the last row among them: deleting a note that two arrows start from can, as their
  rows come out from under it.
- **Selecting rows** (a click, ⌘- and ⇧-clicks, the arrow keys) selects their shapes and brings
  them into view: centered, zoomed to fit with 100 points of margin but no closer than 120%, over
  200 ms (data-canvas's click-to-zoom, and tldraw's zoomToBounds): Selection's `editor.reveal`,
  the one way any plugin brings shapes into view ([Selection](#selection)). A click on one row selects one
  shape, so its details replace the list, as in data-canvas. ⌘- and ⇧-clicks leave several
  selected, and the list keeps listing what it listed, so rows can be added and taken out without
  the rest going away. That holds until the selection next changes some other way, which
  `editor.selectionRevision` tells apart from the same shapes selected again.
- **Hovering links the two.** There's one hovered shape, Selection's `editor.hovered`, and both
  sides set it and show it. The pointer on a row hovers its shape, as the pointer on the shape
  would, and the canvas outlines it faintly. The pointer on a shape on the canvas tints its row:
  a faint accent where the selection's highlight goes, in its shape. A selected shape shows neither,
  only its selection. data-canvas marks a row when its shape is hovered on the canvas (a faint ring);
  its rows don't hover the canvas. A row's tint observes only its own shape's hover
  (`editor.isHovered`) and, while that shape is hovered, the selection, so the pointer moving down
  the list, or across the canvas, redraws the row the hover leaves and the row it reaches. A row
  that read `editor.hovered` instead would be asked for its view again on every hover change, as
  every other row would.
- **Going back.** A row's click is a step in Selection's history like any other change of the
  selection, so the back button in the shape's header (or Go › Back, ⌘[) brings the list back,
  with the view as it was before the zoom, as data-canvas's back button does.
- **The keyboard.** A click gives the list the keyboard, as a source list does: the arrow keys move
  through the rows, Delete runs the `.delete` command (deleting the selected shapes, as Delete on
  the canvas does), and Escape gives the keyboard back to the canvas (`onExit`). So does hiding the panel while the list has the keyboard.
- **Headless**, `ContentsState` (`editor.tableOfContents`) is all of it: `entries` (the rows, a tree),
  `scope`, `select(_:)`, `showAll()`, and the rows' hover: `hover(_:)` and `endHover(_:)` as the
  pointer moves onto a row and off it, and `isHovered(_:)` for whether a row shows as hovered. Tests
  read a row's text, symbol and badge through `entry.label`, and its marks through `entry.marks`.
  In debug builds, `rowsRedrawn` counts how often the list has asked a row for its view.

### Hosting

`DetailPanelView` takes an optional overview, a view it shows where it has no shape to show: in
place of "No Selection", and under the header of several (data-canvas's details panel takes an
`emptyView` and a `multiSelectView` the same way). Neither horizontal knows the other; Composition,
which decides what ships, joins them, and the app places the result in its `.inspector` as before:

```swift
public static func detailPanel(editor: CanvasEditor, onExit: @escaping @MainActor () -> Void) -> some View {
    DetailPanelView(editor: editor, onExit: onExit) {
        TableOfContentsView(editor: editor, onExit: onExit)
    }
}
```

Bringing shapes into view is Selection's `editor.reveal`, which the table of contents calls. It
takes two generic things from the core: `editor.viewportSize`, which
`CanvasView` reports as it's resized, and `editor.animateCamera(to:duration:)`, eased like
tldraw's camera moves and stopped by any other camera change, as the hand tool's slide is.
`Camera(fitting:in:inset:maxZoom:)` (Geometry) does the fit.

## Adornments

An adornment is something small shown on a shape, just outside it or on its corner: a title's
pill, a checklist's tally, a lock. It's a horizontal ([`Sources/Adornments`](../Sources/Adornments))
through which any plugin puts one on any kind, its own, another plugin's, or every shape. Adornments
lays out each shape's, so none overlaps another, draws them, and makes each its shape's for the
pointer. The core has never heard of one.

```
╭─────────────────────────╮ ╭────╮
│ Groceries for the week… │ │lock│    the row, 9 points above the top edge, 18 tall: a title's
╰─────────────────────────╯ ╰────╯      pill at its left end, a lock at its right end, 4 apart
                           ╭───────╮
┌──────────────────────────│ ☑ 1/3 │  the corner, 16 tall, centered on the top edge: a
│ Buy milk                 ╰───────╯    checklist's tally, reaching 6 points past the right edge
│                                │
└────────────────────────────────┘
```

An adornment is never a shape or a record. What it shows is made from its shape's data (its
props, an added property, what the registry says of its kind), so it moves, copies, deletes and
saves with the shape, and there's nothing to attach, keep in step or clean up. None of the three
shipped is placed by the plugin that defines the note: Titles places the pill, Checklists the
tally and Locking the lock, on every shape of the kinds that take part.

### An adornment is a type

An adornment is a type, as a tab or a menu group is: every contribution that names it puts the
same thing in the same place, and a typo doesn't compile. The type says where it goes on its shape
(`placement`) and where among the others there (`order`); what it shows on each shape is a label
the plugin that places it makes from the shape. Locking's chip, whole
([Locking.swift](../Sources/Locking/Locking.swift)):

```swift
public enum LockChip {}

extension LockChip: Adornment {
    public static var placement: AdornmentPlacement { .aboveTopRight }   // the right end of the row above the shape
    public static var order: Int { 300 }                                 // a state that comes and goes: farthest out
}

extension LockChip: ClickableAdornment {
    /// A locked shape's chip unlocks it; a just-unlocked one's locks it again.
    public static func click(on shape: ShapeID, in editor: CanvasEditor) { editor.service(LockState.self)?.click(shape) }
}

// In LockingPlugin.register: on the kinds that can be locked, a lock while a shape is locked, and
// for a moment after, the lock open, fading; on the rest, nothing.
registrar.adornmentForEveryShape(LockChip.self, where: { $0.holds(LockedProperty.self) }) { shape, context in
    if shape.isLocked { return AdornmentLabel(systemImage: "lock.fill") }
    return context.service(LockState.self)?.openLockOpacity(of: shape.id).map { AdornmentLabel(systemImage: "lock.open.fill").opacity($0) }
}
```

- **Conform in an extension**, as for a tab: `order` has a default (0), and only there does the
  compiler flag a near miss.
- **The label says what's shown on one shape**, or nil for nothing there, so a lock shows only on
  a locked shape. Locking a shape shows its chip because the label now says so; nothing is added.
- **A `ClickableAdornment`** is one a click does something with: a [canvas button](#canvas-buttons)
  whose `click(on:in:)` gets the shape it's on ([pointing](#pointing)).

### Placing one

| Sugar | For |
|---|---|
| `x.adornment(A.self) { shape in ... }` | This kind's shapes, inside `registrar.shape { x in ... }`, typed as its own (`ShapeRecord<Props>`). A horizontal's opt-in sugar may call it, so opting in brings its adornment. |
| `registrar.adornment(A.self, on: Kind.self) { shape in ... }` | Another plugin's kind, typed as its own (bridges). |
| `registrar.adornmentForEveryShape(A.self, where:) { shape, context in ... }` | Every shape of the kinds `where` picks (every kind by default), over `AnyShapeRecord`: what a horizontal places on shapes it doesn't define. |

`where` sees each kind once, as an `AdornableKind`: the `kind`, its `definition` (so its
capabilities: `{ $0.definition is any Editable }`), the `registry` (so what else it takes part
in), and `holds(P.self)`, whether its shapes hold an added property, so an adornment that shows
one goes where the property does (Locking's lock: `{ $0.holds(LockedProperty.self) }`, the kinds
that can be locked). Titles and Checklists place theirs this way, on the kinds that opted into their own points:
Titles on those whose title shows a pill (`$0.registry.showsTitlePill($0.kind)`,
[Titles](#a-horizontal-plugin)), Checklists on those that show a chip
([Checklists](#a-horizontals-feature-tab-checklists)). So `note.title()` and `note.checklist()`
bring the pill and the tally, a kind that draws its own says `pill: false` or `badge: false`, and
the report says Titles, which defines no kind, places the pill (`adornment TitlePill → every
shape`). A bridge puts one on a kind it doesn't define, typed:

```swift
public enum SizeBadge {}
extension SizeBadge: Adornment {
    public static var placement: AdornmentPlacement { .onTopRightCorner }
}

registrar.adornment(SizeBadge.self, on: Ellipse.self) { ellipse in AdornmentLabel("\(Int(ellipse.frame.width)) pt") }
```

### Places

Three places, each from the shape's bounds (its geometry's, axis-aligned, so a kind without a frame
has them too), in view points:

| `AdornmentPlacement` | Where | Shipped |
|---|---|---|
| `.aboveTopLeft` | The row just above the top edge, 18 points tall and 9 above it, from its left end rightward, in the room its right end leaves. Text gives way, ending in "…", and needs 30 points: with less, it's left out, and so is what comes after it. | A title's pill |
| `.aboveTopRight` | The same row, from its right end (the shape's right edge) leftward, whole: on a shape too narrow for it, past the shape's left edge. | A lock |
| `.onTopRightCorner` | The top-right corner: 16 points tall, centered on the top edge, from 6 points past the right edge leftward. | A checklist's tally |

In a place, adornments sit 4 points apart. They keep their size on screen down to 25% zoom, and
shrink with the shapes below it (0.4× at 10%). A shape without an outline (nothing drawn) shows
none, and neither does one its board keeps aside. On a 200-point note, in points from its top-left
corner, y down:

| The note | Laid out |
|---|---|
| Unlocked, with a long title | pill (0, −27, 200, 18) |
| Locked, with a long title | lock (182, −27, 18, 18); pill (0, −27, 178, 18) |
| With a checklist | tally (206 − w, −8, w, 16), `w` its text's width and 10 |
| 40 wide, locked and titled | lock (22, −27, 18, 18); 18 points left in the row, so no pill |

So locking a note with a long title shortens its pill by 22 points, the lock's 18 and the 4
between, and unlocking it gives them back once the open lock has faded.

### What's guaranteed

On one shape, by construction (`AdornmentLayout`, pure geometry, which drawing and hit testing both
go by):

- **Nothing in a place overlaps anything else there**: each place is a run, packed 4 points apart.
- **The row's two ends never meet**: its left end runs in the shape's width, less what its right
  end holds and 4 points.
- **The row never meets the corner**: the row ends 9 points above the top edge and the corner
  starts 8 above it (the row's gap is half the corner's height, and a point), so no two plugins
  have to agree on a number.
- **Text at the row's left end is never wider than its room**: it gives way, ending in "…", or,
  with under 30 points, isn't shown.
- **Nothing reaches far**: the row's right end and the corner go no more than 200 points from
  where they start (what would is left out, with what comes after it), and the row's left end stays
  within the shape's width, so every adornment is within x `min(0, width − 200)` … `width + 6` and
  y −27 … 8 of the shape's top-left corner, which culling and hit testing go by.

Not guaranteed: two shapes' adornments may overlap, and stack as their shapes do; an adornment and
another shape may overlap too, and the adornment is drawn over it (and takes presses there). On a
shape narrower than them, the row's right end and the corner run past its
left edge, whole: a lock on a vertical line spans −18 … 0.

### Order

In a place, adornments sort by their type's `order`, then by first appearance: the kind's own,
then every kind's, each in plugin order. The first is nearest where the place starts: the row's
left end, its right end, the corner's outer end. The bands are the tabs' and the menu groups':

| Order | Adornments |
|---|---|
| 0 (the default) | A kind's own |
| 50 | One a horizontal's feature brings to the kinds that opt in (`TitlePill`, `ChecklistChip`) |
| 300 | A state of the shape that comes and goes (`LockChip`): farthest out, so the others keep their places |

So a flag a kind shows of its own keeps its place at the row's right end whether a lock is beside it
or not. Equal orders fall back to plugin order, so unrelated plugins needn't agree on numbers.

### The label

`AdornmentLabel` is what an adornment shows on one shape. Adornments draws every one, so every
plugin's look alike, as `ContentsLabel` keeps rows alike:

- **Text**, `AdornmentLabel("Groceries")`: one line (each run of whitespace, newlines included,
  folds into a space; blank shows nothing), white, in a capsule. In the row it's 11-point medium,
  7 points in from the capsule's ends; on the corner, 10-point semibold figures that line up, 5 in.
- **A symbol**, `AdornmentLabel(systemImage: "lock.fill")`: an SF Symbol, bold and white, in a
  disc as tall as its place, half as tall as the disc.
- **`tone`**: `.neutral` (the default), a title pill's dark gray; or `.success`, green, for
  something done (a checklist with every item checked).
- **`opacity(_:)`**: the same label drawn lighter, 0 to 1 (Locking's open lock, fading).

A clickable one draws lighter hovered and darker pressed. A label can't draw itself (a sparkline):
that's [not built yet](#not-built-yet).

### One of each on a shape

`ShapeAdornments` is keyed: a contribution claims its target and its type, so an adornment is
placed on a kind at most once, and on every shape at most once. Two plugins putting one adornment
on a kind (a kind's own and a bridge's), or two putting one on every shape, are a `conflict`, and
a contribution without Adornments is `ownerNotInstalled`:

```
titles and captions both claim * Titles.TitlePill in ShapeAdornments
titles contributes to ShapeAdornments, but adornments, which owns it, isn't installed
```

A kind's own takes the place of an every-shape one of the same type, as a kind's own menu item
does. So a shape shows each adornment once at most, by construction: a contribution names a type,
never an instance, and there's no second one to attach. There's no `check`: places are a closed
set, and orders needn't be unique. Adornments builds on Selection (a clickable adornment is its
canvas button), so a list with `AdornmentsPlugin` needs `SelectionPlugin` and `KeyboardPlugin` too.
The report shows each on its placer's line: `adornment TitlePill → every shape`, or `adornment Flag
→ box` for one kind.

### What a label reads

A kind's own label, and a bridge's, reads only its shape. One for every shape also gets an
`AdornmentContext`, with what else it may read: the registry (`context.registry`), which never
changes, and a service's state (`context.service(S.self)`), but only a service that tells
Adornments when what it keeps changes: `editor.adornmentsDidChange(for: ids)`. `LockState` keeps
how far each just-unlocked shape's open lock has faded, and says so each frame of the fade.

Adornments makes a shape's labels once, measures them, and keeps them until a commit names the
shape (its `ChangeSet`) or `adornmentsDidChange` does. So a label read from anything else (another
shape, the clock, a service that doesn't say) goes stale. `adornmentsDidChange` also redraws the
canvas, and has the select tool look again for a button under a still pointer
(`canvasButtonsDidChange`), so a lock that comes or goes under it is hovered, or no longer is. A
shape's labels read before Adornments has heard of a commit (by a service that hears first, as
Selection looking for a button under a still pointer) are made afresh and not kept, so they're
never stale, and nothing else is thrown away.

### Drawing and cost

- **One overlay**, `AdornmentOverlay`, draws every shape's adornments, at Adornments' place in the
  plugin list: the shipped app puts `AdornmentsPlugin` after Validation, so they're over its
  outline, and under the marquee and Selection's handles. It goes back to front, a shape at a time,
  so a front shape's adornments are over a back shape's, and all of them are above every shape: a
  back shape's pill shows over a shape in front of it (and takes presses there).
- **Where the shape is drawn.** Adornments follow a [drawing offset](#the-cores-part-drawing-offsets)
  (a locked shape's shake moves its lock and its pill), keep drawing while a session runs (a drag),
  and stay out of the minimap and damage.
- **Only what's in view.** The overlay goes through `editor.paintOrder(in:)` with the visible rect
  grown by as far as adornments reach from their shapes (`AdornmentLayout.area(showing:scale:)`):
  a shape just below the view has its row in it, and a shape up to 200 points to its right can
  have a run reaching back into it. It's grown first by the farthest any shape is drawn from where
  it is (`context.worldDrawingReach`, zero unless one is), so a shape just outside the view that a
  shake draws toward it shows what of its adornments reaches in.
- **Kept, not remade.** `AdornmentState`, a service, finds each kind's adornments once (the
  registry is frozen), and keeps each shape's labels, made and measured, dropping those of the
  shapes each commit's change set names. Where they go is worked out when it's asked, from what's
  kept, since it follows the zoom and geometry that follows other shapes: a few additions per
  adorned shape in view. So a frame costs a lookup and the drawing per adorned shape in view, and a
  drag the labels of what moves. `./build.sh bench` holds a hover and a drag at 10,000 shapes,
  with pills, tallies and locks in view, and a hover onto a pill, to a frame (16 ms).

### Pointing

| Adornment | What the pointer does |
|---|---|
| A `ClickableAdornment` (the lock) | It's a [canvas button](#canvas-buttons), through Adornments' own source: in the select tool, a press and a release on it click it (its type's `click(on:in:)`), before handles and shapes; dragged off, nothing, and Escape lets go. The pointing hand shows over it, and it draws lighter hovered and darker pressed. In other tools it's only drawn. |
| Any other adornment (a pill, a tally) | It's its shape's ([DecorationHits](#drawn-for-a-shape-decorationhits)): hover hovers the shape, a press selects it and a drag moves it, a double-click edits it, and a right-click opens its menu. A clickable one (the lock) is its shape's only for the right-click, which offers Unlock; everything else on it is the button's (a double-click is two clicks). |

- **A hit** is within 3 points of the adornment's capsule, so a disc's is a circle, 12 points from
  its middle, and not its box's corner. Of one shape's adornments the nearest takes it; of several
  shapes', the front-most shape's, as they're drawn, so a front shape's pill over a back shape's
  lock takes the press. Hits go by where a shape is, not where a shake draws it. An unselectable
  shape's adornments are seen through, as it is, but a button isn't: a lock is clicked whatever
  its shape.
- **`editor.hoveredButton`** and `editor.pressedButton` hold an `AdornmentButton` on a clickable
  one: `AdornmentButton(LockChip.self, on: id)`, the type and the shape.
- **`editor.adornmentFrames(of: id)`** is where each of a shape's adornments is now: an
  `AdornmentFrame` each (`adornment`, as `.of(TitlePill.self)`; its `label`; and its `rect`, in
  world units at the current zoom, where the shape is), in the order they're claimed, leaving out
  those without room. It's empty for a shape with none.

### Something the user turns on

data-canvas's sticker put a record beside a shape to say it was public. Here, what the user turns
on is something the shape knows, an [added property](#added-properties), and the adornment only
shows it. A flag, as a horizontal any kind opts into:

```swift
/// Whether a shape is flagged.
public enum FlagProperty {}
extension FlagProperty: ShapeProperty {
    public static let key: PropertyKey = "flagged"
    public static var defaultValue: Bool? { false }       // every flaggable shape has one, for the menu's item to be over
}

/// A flag at the right end of the row above a flagged shape.
public enum FlagChip {}
extension FlagChip: Adornment {
    public static var placement: AdornmentPlacement { .aboveTopRight }
    public static var order: Int { 50 }                   // a horizontal's feature: nearer the row's end than a lock
}

public enum FlagMenuGroup {}
extension FlagMenuGroup: MenuGroup {
    public static var order: Int { 50 }
}

extension ShapeRegistrar {
    /// Lets this kind's shapes be flagged: Flagged in their context menu, and a flag above each that is.
    public mutating func flaggable() {
        optIn(to: FlagProperty.self)
        contextMenu(of: FlagProperty.self) {
            MenuItem("Flagged", in: FlagMenuGroup.self, isChecked: { $0 }) { $0.toggle() }
        }
        adornment(FlagChip.self) { $0[FlagProperty.self] == true ? AdornmentLabel(systemImage: "flag.fill") : nil }
    }
}
```

The plugin declares the property (`registrar.declare(FlagProperty.self)`), and a kind opts in with
one line, `note.flaggable()`, as `note.checklist()` does. What that gives:

- **The fact is the shape's.** It's in the kind's schema, saved with the shape, copied with it (a
  flagged note's copy is flagged) and gone with it; the flag has nothing of its own to keep in
  step, and a board opened without the plugin keeps the value aside and saves it back.
- **One flag per shape**, by construction: the label says whether there is one.
- **The default is `false`, not nil**, so every flaggable shape has a value, which the menu's item
  is over. With a nil default only flagged shapes would carry it, as locked ones carry `locked`,
  but an item over the value shows only once it's set ([not built yet](#not-built-yet)), so the
  item would be one for the canvas, as Locking's Lock and Unlock are.

## The clipboard

Cut, copy and paste are a horizontal ([`Sources/Clipboard`](../Sources/Clipboard)) built on three
others: Selection (what's copied, and what's selected after a paste), Keyboard (⌘X, ⌘C and ⌘V) and
ContextMenus (Cut, Copy and Paste in every context menu). The core has never heard of a clipboard. It
lends three generic things: commands (`.cut`, `.copy` and `.paste`, which Edit › Cut, Copy and
Paste send), shape [metadata](#metadata), and the `ShapeReferencing` [capability](#capabilities).

| | Does |
|---|---|
| ⌘C, Edit › Copy, Copy | Puts copies of the selection's copyable shapes on the pasteboard, back to front. The board doesn't change. |
| ⌘X, Edit › Cut, Cut | Copies, then deletes what it copied, in one transaction. What can't be copied stays, and so does a [locked](#locking) shape, copied all the same (it shakes, as with Delete). |
| ⌘V, Edit › Paste, Paste | Puts the copies on top of the board, with new ids, and selects them. |

- **Copies get new ids, and remember their originals.** Each pasted shape's metadata names the
  shape it was copied from: `record.copiedFrom`, which is `meta[CopiedFrom.self]?.shape`, and its
  board keeps it. That's the shape the copy was made from: a copy, if a copy was copied; in
  whichever board it was copied from, this one or another; and maybe gone since (a cut shape always
  is). Pasting twice makes two copies of the same shapes. The rest of a shape's metadata comes
  with it, and so do its [added properties](#added-properties)' values: a locked shape's copy is
  locked, as tldraw's is. A paste moves its copies (`translate`) in the transaction that puts them
  in, which a lock doesn't stop.
- **Where a paste lands** is tldraw's: where the originals were, if any of them would be in view
  there; otherwise centered in the view, the shapes keeping their places among themselves. A paste
  in place lies exactly over its originals, as in tldraw and Figma. Moving them is
  `transaction.translate(ids, by:)`, which moves every kind as dragging would: boxes by their frame,
  others by their `CustomTranslation`.
- **Shapes bound to shapes.** A kind whose props are bound to other shapes (an arrow's bound ends)
  adopts the core's `ShapeReferencing`, which deleting a shape asks too. Copying asks it to let go
  of the shapes left out of the copy, and pasting asks it to bind the copies of those copied with it. So
  two notes and the arrow between them paste as two notes and an arrow between the copies, and an
  arrow copied alone pastes free, ending where it was drawn, as it would if its notes were deleted.
  tldraw's copy does the same. A shape that can't let go of one it can't find (an arrow bound to a
  shape its board keeps aside, or one a paste can't read) is left out, rather than copied wrong.
- **Shapes that only name shapes** ([`ShapeNaming`](#values-that-name-shapes), a mention) go through
  the same call, `record.remappingReferences`, which renames their names too: a copy names the
  copies of the shapes copied with it, and goes on naming the rest. Clipboard needs nothing of its
  own for them.
- **The pasteboard** holds a small board: `BoardCodec`'s JSON, each kind and added property at its version, under the
  app's own type. So one window can paste what another copied, a paste into a newer app migrates as
  opening a board does, and a kind the board doesn't install is left out of a paste. Anything else
  on the pasteboard (text, an image from another app) is left alone for now. ⌘V, Edit › Paste and
  Paste are there only when something would paste, so otherwise ⌘V's key goes on. The pasteboard is
  read again only when it's changed. `ClipboardPlugin(pasteboard:)` takes the pasteboard, the
  system's by default.
- **Where the keys work.** ⌘X, ⌘C and ⌘V are Keyboard's while the canvas has the keyboard.
  Elsewhere the menu has them: the board's window controller answers Edit › Cut, Copy and Paste
  wherever the keyboard is, the table of contents' list included, except in text (a note being
  edited, a panel's field), which takes them first. Cut and Paste don't run mid-gesture; Copy does.
- **Undo.** Cut and Paste are one step each, "Cut" and "Paste", by key, menu or context menu.
  Undoing a cut brings the shapes back selected; undoing a paste selects what was before it, and
  redoing it brings back the same copies (the same ids, `copiedFrom` and all).
- **In the context menu**, Cut, Copy and Paste are items for the canvas
  (`registrar.contextMenuForCanvas`), in `ClipboardMenuGroup` (order 100, before Arrange), asked
  once per menu. Cut and Copy show when some of the menu's shapes can be copied, and act on those;
  Paste shows when something would paste, on shapes and on empty canvas.

**Opting out.** Every kind is copyable unless it says otherwise, for all its shapes or for some, as
with selecting:

```swift
registrar.shape(TicketDefinition()) { ticket in ticket.uncopyable() }
registrar.shape(StampDefinition()) { stamp in stamp.copyable { !$0.props.isSealed } }
```

A selection's uncopyable shapes are left out of a copy, and stay when it's cut. With only such
shapes selected, ⌘C and ⌘X pass the key on, and the menu has no Cut or Copy. Everything
else treats them as usual: they're selected, moved, deleted and erased. The rule is
`ShapeCopyability`: at most one per kind, plus one for every kind, which a kind's own overrides.

### Metadata

A shape's metadata (`AnyShapeRecord.meta`) is the core's place for what a plugin keeps about a
shape, such as where it was copied from, as opposed to what the shape knows: its kind's properties,
and those plugins add to it ([Properties](#properties-and-metadata)). A member is typed by a key the
plugin that owns it declares, as an extension point is:

```swift
public enum CopiedFrom {}
extension CopiedFrom: ShapeMetaKey {
    public typealias Value = CopySource        // { shape: ShapeID }
    public static var owner: PluginID { .clipboard }
    public static var name: String { "copiedFrom" }
}
```

Read it with `record.meta[CopiedFrom.self]`, and change it in a transaction:
`tx.update(id) { $0.meta[Key.self] = value }`. A board keeps it beside the props, under the
owner's id, then the name (`"meta" : { "clipboard" : { "copiedFrom" : { "shape" : "…" } } }`), so
two plugins' members never share a place; members no installed plugin knows are kept, and a copy
(`record.copy(as:)`) takes it along. A board with any metadata is format 2 at least, which an app
from before it won't open rather than save without it; opening one leaves out metadata that isn't an
object for each plugin, and says so (`LoadReport.Repair.droppedMeta`). Unlike props, members
aren't versioned: add only optional fields to a value, since one that no longer decodes reads as
nil.

## Locking

A locked shape can't be changed: not moved, restacked, resized, edited or deleted, whatever tries,
until it's unlocked. Each try shakes it a little, and a lock chip sits just above its top-right
corner. Shapes are locked from the context menu, and unlocked there or with a click on the chip,
which shows the lock open for a moment, where a click locks the shape again. It's a horizontal
([`Sources/Locking`](../Sources/Locking)) that every kind is in, built on Adornments, ContextMenus
and Selection; the core has never heard of a lock. It lends two generic things, read-only shapes
and drawing offsets, [Adornments](#adornments) lays out, draws and points the chip (a clickable
adornment, so a [canvas button](#canvas-buttons)), and Locking does the rest
([Locking.swift](../Sources/Locking/Locking.swift)):

```swift
registrar.declare(LockedProperty.self)                  // `locked: true` on a locked shape; nothing on the rest
registrar.optInEveryShape(to: LockedProperty.self)
registrar.readOnlyShapes { $0.isLocked }                // the core refuses changes to them
registrar.service { LockState(editor: $0) }             // which shapes are locked, open locks, the shakes and fades under way
registrar.adornmentForEveryShape(LockChip.self, where: { $0.holds(LockedProperty.self) }) { shape, context in  // the chip, where a shape can be locked: closed while locked, open a moment after
    if shape.isLocked { return AdornmentLabel(systemImage: "lock.fill") }
    return context.service(LockState.self)?.openLockOpacity(of: shape.id).map { AdornmentLabel(systemImage: "lock.open.fill").opacity($0) }
}
registrar.contextMenuForCanvas {
    MenuItem("Lock", in: LockMenuGroup.self, when: { !$0.shapes.isEmpty && !$0.allLocked }) { ids, editor in editor.lock(ids) }
    MenuItem("Unlock", in: LockMenuGroup.self, when: { !$0.shapes.isEmpty && $0.allLocked }) { ids, editor in editor.unlock(ids) }
}

extension LockChip: ClickableAdornment {                // a click on the chip
    public static func click(on shape: ShapeID, in editor: CanvasEditor) { editor.service(LockState.self)?.click(shape) }
}
```

- **A lock is something the shape knows**, as tldraw's `isLocked` is: an [added
  property](#added-properties), `locked`, that every kind opts into, so it's in every kind's schema
  and saved with the shape (`"added" : { "locked" : true }`). Its default is nil, so only locked
  shapes carry it, and unlocking takes it away. Read it with `record.isLocked`, and change it with
  `editor.lock(ids)` and `editor.unlock(ids)`, each one transaction.
- **The menu** has one of two items, in `LockMenuGroup` (order 300, after every other group), as
  tldraw's toggle: Unlock when every shape the menu is for is locked, and otherwise Lock, which locks
  the rest. They're items for the canvas, so a mix of locked and unlocked shapes gets one; on empty
  canvas, neither. There's no key: the menu is the only way to lock a shape.
- **The chip is a button** (`LockChip`, a [clickable adornment](#pointing), so a canvas button): in
  the select tool, a click on a locked shape's chip unlocks it. Then the chip shows the lock open
  for 1.5 s, however the shape was unlocked (the menu too), so a click by mistake can be taken back:
  a click on the open lock locks the shape again. It stays while the pointer's on it (looking again
  every 0.5 s), then fades over 0.3 s and is gone, since an unlocked shape has no chip. The pointing
  hand shows over a chip, which draws lighter hovered and darker pressed, and a click on one selects
  nothing. A right-click on it is on its shape, as on any adornment: the menu offers Unlock.
- **Everything refuses a locked shape**, since everything changes shapes through a transaction.
  A drag leaves it where it is and moves the rest of the selection (a click, even one that jitters
  under the drag threshold, doesn't count as a try); Delete, Cut and the eraser leave it and take
  the rest; Return and a double-click don't edit it; it shows no handles; Arrange doesn't restack it;
  a menu item that edits it changes nothing. Each of those shakes it.
- **What isn't a change still works.** It's selected, hovered, outlined, copied, listed and bound
  to (an arrow may start or end on it) as any other shape. An arrow bound to a shape that moves
  follows it, locked or not, since its props don't change; and a locked arrow still lets go of a
  shape that's deleted (`ShapeReferencing`), which keeps it where it's drawn. The detail panel shows
  a locked shape's details, disabled.
- **Undo.** Each lock and unlock is a step of its own, "Lock" or "Unlock" (from the menu or the
  chip). Undo is below the read-only rule, so undoing Lock unlocks the shape without a shake (its
  chip shows open, as for any unlock), redoing it locks it again, and undoing a chip's Unlock locks
  it. A try a lock refuses (a drag, Delete) changes nothing, so it records nothing: the next ⌘Z
  undoes the step before it.
- **The shake** is a password field's: side to side, 5 points at most, 3 times over 360 ms, dying
  away, a frame every 16 ms on `editor.scheduler`. A try while it plays (the eraser dragged across)
  doesn't start it over. `LockState` hears the tries (`didRefuseChanges`), and moves how the shape
  is drawn, never the shape: `editor.setDrawingOffset(_:for:)`.
- **The chip** is an 18-point disc with a lock, the dark of a title's pill, at the right end of the
  row just above the shape, ending at its right edge. Its order is 300, a state that comes and
  goes, so it's farthest out of what's at that end, and a title's pill at the other end stops 4
  points short of it. Adornments lays it out with the rest, keeps its size on screen down to 25%,
  and draws it where its shape is drawn, so it shakes with it. A click within 3 points of its edge
  still clicks it. The open lock, fading, is a label from what `LockState` keeps
  (`openLockOpacity(of:)`: nil but for a shape just unlocked), and `LockState` tells Adornments
  each time it changes (`editor.adornmentsDidChange(for:)`: the lock opening, each frame of its
  fade, and its going), so the chip's label is made again only then, or when a commit changes the
  shape.

### The core's part: read-only shapes

`registrar.readOnlyShapes { record in ... }` says which shapes can't change; a shape is read-only
when any plugin's rule says so, and `editor.isReadOnly(id)` (or `registry.isReadOnly(record)`,
which doesn't read the document) asks. The core holds them where every change goes through it:

- **Transactions.** A read-only shape that was in the document before the transaction isn't
  changed (`update`), restacked (`bringToFront`, `move(_:above:)`, ...), moved (`translate`) or
  deleted by it. The change is dropped, the rest of the transaction stands, and once it's done
  services hear every shape it refused: `EditorService.didRefuseChanges(to:in:)`. A change that
  leaves the shape no longer read-only goes through, whatever else it changes (unlocking, tldraw's
  rule too), and so does one that makes it read-only. A shape the transaction put in isn't held
  (a paste moves its locked copies into place). Nor is what a deletion does to keep the board
  whole: its `willDelete` handlers' changes (a read-only dependent goes with the shape it depends
  on, as a locked shape in tldraw goes with its deleted parent), and shapes letting go of what's
  deleted (`ShapeReferencing`).
- **Drags.** A `TranslatingSession` leaves read-only shapes out of what it moves (so a
  `CustomTranslation` knows what moves with it), and tells services once the pointer passes the drag
  threshold, once.
- **Editing.** `beginEditing` refuses a read-only shape, and services hear it; a shape that becomes
  read-only while it's edited stops being edited.

Selection shows no handles on a read-only shape, and the detail panel disables its controls; both
ask the core, not Locking. A rule reads only the record it's given, since a transaction asks it of a
shape before and after a change, and the panel of the record it shows (and redraws only when that
changes). It's asked about every shape a transaction changes, so keep it cheap: Locking's reads one
added value.

### The core's part: drawing offsets

`editor.setDrawingOffset(offset, for: id)` draws a shape `offset` view points from where it is, until
it's set back to zero: an animation that moves how a shape looks without changing it. The core
draws the shape and its outlines there; an overlay that decorates a shape moves its decoration by
`context.worldDrawingOffset(of:)` (the same offset, in world units), as Adornments does for every
[adornment](#adornments) (a title's pill, a checklist's tally, the lock chip) and Validation for its
outline. One that culls by the view can grow the rect by `context.worldDrawingReach`, the farthest
any shape is drawn from where it is (world units, zero unless one is), so a shape drawn into view
from just outside it is decorated there, as Adornments does. Everything else goes by where the
shape is: hit testing, handles, arrows bound to it, and pictures of the board (the minimap).
Deleting a shape drops its offset.

## Ports

Ports are data-canvas's: dots just outside the sides of the shape the pointer is over, from which a
drag draws an arrow to another shape. Not to any shape: each port is on a channel, a kind of
connection, and the arrow may end only on a shape that takes its channel, so a note links to a note
and a task to a task, never one to the other. It's a horizontal ([`Sources/Ports`](../Sources/Ports))
any kind opts into, built on Selection, whose [canvas buttons](#canvas-buttons) the dots are; the
core has never heard of a port, and Ports has never heard of an arrow: a bridge,
[ArrowPorts](#the-connector-arrowports), makes arrows what a drag from a port draws. Ports itself
([Ports.swift](../Sources/Ports/Ports.swift)):

```swift
registrar.declare(ChannelProperty.self)                 // `channel` on a connection drawn from a port
registrar.service { PortState(editor: $0) }             // every kind's ports, and whose dots show
registrar.overlay(PortOverlay())                        // the dots; while a connection is drawn, what it could end on
registrar.canvasButtons(at: { editor, point in editor.service(PortState.self)?.dot(atViewPoint: point) },
                        drag: { dot, origin, editor in editor.service(PortState.self)?.connect(from: dot, at: origin) })
```

and what a sticky note adds, its channel and its ports
([NoteLinks.swift](../Sources/StickyNotes/NoteLinks.swift), [StickyNotes.swift](../Sources/StickyNotes/StickyNotes.swift)):

```swift
public enum NoteLink {}

extension NoteLink: Channel {
    public static let id: ChannelID = "note-link"
    /// A brown amber, darker than the note, so a dot reads beside one.
    public static var color: NSColor { NSColor(srgbRed: 0.70, green: 0.45, blue: 0.05, alpha: 1) }
}

extension ShapeRegistrar where Definition == StickyNoteDefinition {
    /// Ports on every side but the top, where a titled note's pill is.
    mutating func noteLinks() {
        ports(NoteLink.self, sides: [.left, .right, .bottom])
    }
}

// In StickyNotesPlugin.register:
registrar.shape(StickyNoteDefinition()) { note in
    ...
    note.noteLinks()                                   // and ports: arrows from a note to a note
}
registrar.channel(NoteLink.self)                       // which this plugin declares
```

Task cards do the same with `TaskLink` (`task-link`, purple), on all four sides, since a card draws
its title inside and nothing sits above it ([TaskCardLinks.swift](../Sources/TaskCards/TaskCardLinks.swift)),
and so do [schema cards](#schema-cards), with `SchemaLink`. The channels say nothing more yet: a
channel is where a connection's meaning would go (one task blocking another, say).

### Channels

- **A channel is a type** (`Channel`), as a tab or an added property is: its `id` (`ChannelID`)
  and the color of its dots (`static var color`, computed, since colors aren't `Sendable`; gray by
  default). The plugin that owns what a connection on it means declares it,
  `registrar.channel(C.self)` (the `Channels` point: a channel declared twice is a `conflict`), and
  kinds have ports on it by its type, so a plugin that gives a kind ports on another's channel
  imports that plugin's module. StickyNotes declares `NoteLink` for its notes, TaskCards
  `TaskLink` for its tasks, and Schemas `SchemaLink` for its cards; a channel that joins kinds of several plugins would be declared by the
  horizontal whose meaning it is (data-canvas's `registerHostChannel` calls come from such a
  feature), and given to their kinds by bridges.
- **The id never changes once shipped**, since connections keep it. The id audit holds a
  `ChannelID` literal to the module that declares it, as it does a kind
  ([The module graph](#the-module-graph)).
- **What a connection knows is its channel**: `ChannelProperty` (key `channel`), an [added
  property](#added-properties) Ports declares and the connector's kind opts into. It has no
  default, so only a connection drawn from a port has one (`"added" : { "channel" : "note-link" }`),
  and an arrow drawn with the arrow tool has none. In the arrow's schema it's a string of at least
  one character, since the channels are whatever plugins declare; its fixture is
  `Fixtures/added/channel.v0.json`.

### A kind's ports

`x.ports(C.self, sides:role:)` gives a kind ports on a channel (`registrar.ports(K.self, on:
C.self, sides:role:)` for another plugin's kind, from a bridge). It's the `ShapePorts` point, one
contribution per kind and channel, and a kind may have ports on several:

- **`sides`** (`PortSide`: `.top`, `.right`, `.bottom`, `.left`; all four by default) are where
  its dots are, one just outside the middle of each. A side with ports on several channels has one
  dot, in its first channel's color, and a connection from it is drawn on the first of its channels
  the shape it ends on takes.
- **`role`** (`PortRole`, a data-canvas port's end) is what the ports let the kind be: `.both`
  (the default), `.source` (its dots start connections, and none ends on it) or `.target`
  (connections end on it, and it has no dots).

The registry refuses ports on a channel no installed plugin declares, and ports on the connector's
own kind, since a connection neither starts nor ends on another (`ShapePorts.check`):

```
ShapePorts: ratings gives box ports on channel wire, which no installed plugin declares
ShapePorts: ratings gives arrow ports, but it's what connections are
```

Its report shows `ports note-link → sticky-note` on the line of the plugin that gives the kind its
ports, and `channel note-link` on the declarer's. Rules about connections already drawn go by
`registry.accepts(shape, on: channel, as: .source)` (or `.target`), whether a shape's kind takes a
channel at that end, and `registry.declares(channel)`. `editor.channel(of: connection, endingAt:
record)` is the channel a connection would be drawn on if it ended at a shape: the first of its
channels the shape's kind takes as a target, and nil for the shape it starts from, a shape kept
aside, or one that takes none.

### The dots and the select tool

The dots are canvas buttons, dragged rather than clicked (`PortDot`: a shape and a side, what
`editor.hoveredButton` and `editor.pressedButton` are while the pointer's on one). They show for
one shape at a time, the host, as data-canvas's show on the hovered shape:

- **Whose.** The shape whose dot the pointer is on, any shape's (so a dot the pointer comes to
  straight from empty canvas shows its shape's, as data-canvas's halo does); else the shape the
  pointer's over, if it has dots; and over empty canvas or a shape without ports, the last one,
  while the pointer stays within reach of its dots (its bounds grown by 24 view points, a dot's 12
  out and its 12 of reach), so the pointer can leave a shape for one of its dots. None while a handle is under the pointer, which takes the
  hover from shapes as it does in Selection, and none once the tool changes or the shape is
  deleted. A shape has dots when its kind has a side with ports that aren't `.target`, it isn't
  kept aside, and the connector can start from it (`canConnect`: an arrow can bind to it, so it's
  closed and isn't an arrow).
- **When.** In the select tool, while the pointer's over the canvas (`editor.pointerOverCanvas`)
  and, where it is now (`editor.pointerWorldLocation`, so not after Escape with the press held
  elsewhere), within reach of them, and nothing is under way but a dot's press, at 25% zoom and up, where the chips start to shrink:
  further out, a shape is too small on screen for its dots to be told from its neighbors'. And only
  with a connector installed: without one, no shape shows ports.
- **Where.** 12 view points out from the middle of each of its sides of the shape's bounds (its
  geometry's), constant on screen, and where the shape is drawn, so they shake with a locked shape.
  A dot shows, and is pressed, only while no selectable shape painted above its own covers its
  center (an arrow leaving the shape there, a neighbor on top: `PortState.liveDots(of:)`), so what
  shows is what a press there presses, and a shape lying on a bigger one shows its dots over it.
- **How they look.** A disc 8 points across in its channel's color at 60%, in a white ring (1.5
  points); hovered or pressed, 10 points across at full color, in a halo of the color at 24% 24
  points across, its reach, as a handle's is (`PortStyle` gives the radii: 4, 5 and 12). The open hand shows over one, the closed hand while
  one's pressed.
- **A press** within 12 view points of a showing dot's center (the nearest, if several) is the dot's,
  whatever is under it. Where the select tool hasn't seen the pointer move (just after a tool
  change, or a first click into the window) no dot shows, so none takes the press: it's the
  canvas's, or the shape's. Past the drag threshold, the connector draws a connection from it;
  released without a drag, nothing happens; Escape lets go. Ports comes after Adornments in the
  shipped list, so a dot is found before an adornment it overlaps (a lock chip, a clickable
  adornment, among them), and draws above it.
- **While a connection is drawn** the dots are gone, and each shape in view it could end on is
  outlined faintly, as a hovered shape is (2.5 points, the accent at 60%); the shape it would end
  on now gets the full outline, the hint.
- **Locked shapes keep their ports.** A connection to or from one changes an arrow, never the
  shape.
- **What it costs.** `PortState` finds every kind's ports once, as the registry is frozen. The
  select tool asks for the dot under the pointer as it moves, which looks at the dots of the few
  shapes near the pointer, and at what's painted above one only for a dot within 12 points, and
  then only between the middle of its side and its center (`liveDots(of:on:)`); the overlay draws
  one shape's dots, those in view. While a connection is drawn, the overlay goes through
  `editor.paintOrder(in:)` with the visible rect. `./build.sh bench` holds a hover on a note's dot
  and a drag from it at 10,000 shapes to a frame.

### The connector: ArrowPorts

Ports never learns what a connection is. One plugin draws them, the connector
(`registrar.connects(K.self, canConnect:begin:)`, the `Connectors` point, at most one). `K` is what
connections are, and opts into `ChannelProperty`; `canConnect` says which shapes one may start
from and end on; and `begin`, given the drag's `Connection` (the port's shape and side, the dot's
channels in plugin order, and where it was pressed, in world units), returns the session that
draws it, which the dot's press hands the drag to, or nil to draw nothing. The bridge
([ArrowPorts.swift](../Sources/ArrowPorts/ArrowPorts.swift)) makes arrows the connector, though
Arrows has never heard of a channel:

```swift
registrar.connects(Arrow.self, canConnect: { id, editor in editor.canBindArrow(to: id) }) { connection, editor in
    editor.beginArrow(from: connection.shape, at: connection.origin,
                      canBind: { editor.channel(of: connection, endingAt: $0) != nil },
                      complete: { arrow, end in
                          guard let shape = editor.document[end] else { return }
                          arrow[ChannelProperty.self] = editor.channel(of: connection, endingAt: shape)
                      })
}
registrar.arrowBindingRule { query in
    guard let channel = query.arrow[ChannelProperty.self], query.registry.declares(channel) else { return true }
    return query.registry.accepts(query.shape, on: channel, as: query.end == .start ? .source : .target)
}
```

- **A drag from a dot draws an arrow.** Its start is bound to the port's shape, aiming at its
  center, and its end follows the pointer, binding by tldraw's rules as the arrow tool's does
  (arriving fast, it aims at a shape's center; arriving slowly, or after a 320 ms pause, at the
  spot; ⌥ runs all the way to it, ⌘ or ⌃ binds nothing, ⇧ snaps the angle), but only to a shape
  that takes one of the port's channels, looking through the rest to the shapes behind. Released
  on one, the arrow keeps the channel it's drawn on; released anywhere else, or on Escape, it's
  deleted, and nothing is drawn. Its binding hints are the arrow tool's.
- **A drawn arrow keeps to its channel** (the rule): re-aimed or moved, each end binds only to a
  shape that takes the channel at that end, the start as a source and the end as a target,
  looking through the rest. An arrow without a channel (the arrow tool's), or with one no installed
  plugin declares (a board from an app with another plugin), binds wherever an arrow can.
- **It differs from tldraw** on three counts, as data-canvas's does: released free, the arrow is
  deleted, where tldraw's keeps a free end; its start binds the port's shape at its center,
  imprecise, with none of the arrow tool's hover and press timers; and the selection and the tool
  are left as they were, where the arrow tool selects its arrow and goes back to Select.

What Arrows lends, it lends any plugin, and it knows no channel
([ArrowConnecting.swift](../Sources/Arrows/ArrowConnecting.swift)):

- **`ArrowBindingRules`** (`registrar.arrowBindingRule { query in ... }`, a list) is tldraw's
  canBind: an end binds only to a shape every rule allows, looking through the rest. A rule gets an
  `ArrowBindingQuery`: the arrow as it is (its props and added values), the end, a shape under the
  end, and the registry. It's asked wherever an end binds: drawn, re-aimed (the precise timer and a
  modifier's change included) or moved alone (`beginTranslation`'s probe), and only of the shapes
  the point hits, but as the pointer moves, so keep it cheap. With no rule nothing is filtered,
  and arrows behave as they did before.
- **`editor.canBindArrow(to:)`** is whether an arrow can bind to a shape: it's there, it's closed,
  and it isn't an arrow.
- **`editor.beginArrow(from:at:canBind:complete:)`** draws an arrow for another plugin's gesture:
  it inserts one, its start bound to the shape (imprecise) and its end at `origin`, and returns the
  session that drags its end, for the caller to hand the drag to (nil if an arrow can't bind to the
  shape). Released bound, `complete` gets the arrow's record and the shape its end is bound to, in
  the transaction that finishes it.
- **`BindingHintsOverlay`** draws the hints of the arrow being dragged, else the selected arrow's,
  so an arrow drawn from a port, which leaves the selection alone, hints as the tool's does.

Ports are the part of data-canvas's that notes and tasks need to prove the API; the rest is in
[Not built yet](#not-built-yet).

## Mentions

Mentions ([`Sources/Mentions`](../Sources/Mentions)) lets text mention other shapes: `@` in a
note, a few letters of a task's title, Return, and the note says "Ask ⟨▢ Ship the beta⟩ first",
the mention an inline pill with the task's symbol and name. It's a horizontal on Selection, the
table of contents and Titles, and two kinds opt in: sticky notes, whose text holds mentions and
which can be mentioned, and task cards, which can be mentioned. The core knows no mention; what
Mentions needs of it is generic: [names](#values-that-name-shapes) of shapes that may outlive them,
[faces](#faces-clickable-parts-of-a-shape), [going to shapes](#selection), and
[rows read from more than their shape](#rows-read-from-more-than-their-shape).

```swift
// In StickyNotesPlugin.register:
registrar.shape(StickyNoteDefinition()) { note in
    ...
    note.noteRow()                                               // its row reads its mention text (below)
    note.mentionText { $0.mentionTexts }                         // where its text, with pills, is drawn
    note.mentionable(untitled: { $0.props.text.firstLine })     // called by its title, else its first line
}

// In TaskCardsPlugin.register:
task.mentionable(symbol: { $0.props.status.symbol })            // called by its title; its symbol its status's
```

### Mentionable kinds

A kind opts into being mentioned with `x.mentionable(label:untitled:symbol:detail:tint:)`, one per
kind (the `ShapeMentions` point; `registrar.mentionable(K.self, …)` from a bridge, and
`registrar.mentionableEveryShape(where:)` for a composition that wants every kind, which a kind's
own takes the place of). Every closure reads only the shape, as a title does, so a pill changes
only when its shape does:

- **Its name** is `label`, else the shape's title (Titles' `registry.title(of:)`, named or
  derived), else `untitled`, else "Untitled" and the kind's name ("Untitled Task"), each on one
  line, blank counting as none. A note that isn't titled is called by the first line of its text
  with words in it (`firstLine`), each mention there "@…" ("See @… first"): it names no other
  shape, live or as its mentions hold them. A mention holds its target's name as it was written,
  and an untitled note's name is its first line, so if its mentions' names were in it, two notes
  that mention each other would each take in the other's name, and their own with it, every time
  either was written.
- **Its symbol** is `symbol`, else its placing tool's; `detail` is said beside the name in the
  picker (the kind's name by default), and `tint` colors the symbol where the surface is neutral.

`registry.mentionAppearance(of:)` is how a shape shows (`MentionAppearance`), and
`registry.mentionResolution(of:lookup:)` what a mention of an id shows now (`MentionResolution`):
`.live` with its appearance, `.missing` for no such shape on the board, or `.unavailable` for one
kept aside or whose kind can't be mentioned, which shows as missing.

### Mention text and its stored form

Text holds mentions when its type is `ScopedMentionText<Scope>`; `MentionText` is
`ScopedMentionText<AnyMentionable>`, any mentionable shape. A sticky note's `text` is one:

```swift
Property("text", \.text).description("What the note says.")    // public var text: MentionText
```

It's stored as **one string**, so a board, the schema and the command line see a plain string, an
older app shows readable text, and there's no second structure to fall out of step:

```
Ask @[Ship the beta](shape:0A1B2C3D-4E5F-4061-8293-A4B5C6D7E8F9) first
```

- **The grammar.** `@[name](shape:UUID)` is a mention (any case of UUID); in a name, `\]` is `]`
  and `\\` is `\`; in the text, `\@[` is a literal `@[`, and backslashes just before an `@[` are
  doubled. Anything that isn't a whole mention is text, byte for byte. The schema's definition
  (`mentions.text`, which every scope refers to) says so, for agents; it's a string without bounds,
  and the registry refuses mention text given a length or a pattern (`MentionTextFormat.checkBounds`).
- **The value.** `runs` (`MentionRun`: `.text(String)`, `.mention(ShapeID, label:)`) are parsed
  once, as it's made. `stored` is the string it was made from, and equality compares it, so a
  board's text, or an agent's lowercase id, writes back as it was read; text made from runs
  (`MentionText([.text("Ask "), .mention(id, label: "Ship"), …])`, what every Mentions surface
  writes) is canonical, ids in uppercase. A string literal is plain text, as is `init(plain:)`:
  `StickyNote(text: "Hi")` never gains a mention. `mentioned`, `isBlank`, `firstLine` ("Ask @…
  first") and `plainText(label:)` ("Ask @Ship the beta first") read it.
- **The name a mention holds is a snapshot**, what its shape was called when the text was last
  written. The app shows it only while the shape isn't live; everywhere else it shows the shape's
  name now.
- **A mention is a name, not a binding** (`ScopedMentionText: ShapeNaming`, coded by hand). Deleting
  the shape writes nothing: its pills show the name they hold, dashed, and undoing the deletion,
  which puts the shape back as it was, id and all ([Undo](#undo)), brings them back to life;
  redoing it, they're missing again. A copy renames the mentions of shapes copied along and keeps the rest
  (a note pasted on another board mentions a shape that isn't there, which shows as missing), and
  `canvas create` makes a note that mentions a shape that isn't there, with a warning.
- **The migration.** A note's text became `MentionText` in its third step,
  `PropsMigration("text may mention shapes")`, which escapes what would now read as a mention
  (`MentionTextFormat.escapeLookalikesV1`), so old text stays the text it was. The escaper is
  frozen, as a shipped step is: a later grammar gets a new one.

### Scopes: what a text may mention

A text's scope is its type parameter, a `MentionScope` (conformed to in an extension): whether it
admits a shape, and what its schema says of it (`x-canvas-mentions`, beside the reference).

- `AnyMentionable`: every mentionable shape (`MentionText`).
- `Only<Kind>`: one kind, which must be mentionable. A vertical names only its own kind, since no
  vertical imports another: `ScopedMentionText<Only<SchemaCard>>`.
- A **declared scope** (`DeclaredMentionScope`, with a `title`), which the plugin that owns its
  meaning declares, `registrar.mentionScope(Blockers.self)` (the `MentionScopes` point; no two
  titled alike), and kinds join from their own plugin or a bridge, `x.mentionable(in:
  Blockers.self)` or `registrar.mentionable(TaskCard.self, in: Blockers.self)` (a kind must be
  mentionable to join, and the scope declared).

A scope limits what the picker offers, and the schema says it. It never refuses a mention that's
there (pasted, or written by an agent), as a bound is a guideline. No shipped text is restricted
yet: a note's mentions any mentionable shape. MentionsTests hold scopes with fixtures (a `Brief`
holds text of `Only<Plate>` and of `Blockers`, which plates and tokens join).

### Drawing

A kind lists where it draws mention text, from the shape alone, and its render draws exactly those:

```swift
extension ShapeRecord where Props == StickyNote {
    @MainActor var mentionTexts: [MentionTextPlacement] {
        [MentionTextPlacement(props.text, in: props.frame.insetBy(dx: NoteStyle.padding, dy: NoteStyle.padding), style: NoteStyle.text)]
    }
}

func render(_ shape: ShapeRecord<StickyNote>, in context: RenderContext) {
    context.fillWithShadow(NoteStyle.path(shape.frame), NoteStyle.color)
    guard !context.isEditing else { return }                     // the editing view draws the text
    for placement in shape.mentionTexts { context.drawMentionText(placement) }
}
```

- **The style** (`MentionTextStyle`: a font, a color, a fixed line height, and its
  `MentionSurface`) is shared by the render and the editor, as `NoteStyle.text`; its `attributes`
  are what the editor types with. On a shape's surface a pill is monochrome, the text's own color
  at a few strengths (a yellow tint on a yellow note would vanish); on a neutral one (the picker),
  its symbol takes the kind's tint.
- **The pill** (`MentionAttachment`, one U+FFFC character) is the kind's symbol and the name, no
  "@", its metrics fractions of the font's size (`MentionStyle`): 17 points tall in 16-point text,
  so a note's lines keep their 19 points; at most 16 em wide, or the line, its name ending in "…".
  A missing one has no fill, a dashed outline, and its name in italic. Its image is drawn afresh
  wherever it's drawn, never kept as a bitmap (`cacheMode` `.never`): the canvas keeps thousands
  of pills built, and a bitmap for each scale they're drawn at would come to hundreds of megabytes
  after a pan at 400%.
- **`drawMentionText`** is string drawing, as the note's plain text always was: text with no
  mention draws exactly as a plain string with the style's attributes, pixel for pixel. Text with
  mentions is resolved through the render's `shapes` (a render's lookups aren't tracked, but the
  canvas redraws what's in view on every commit, so a rename shows the next frame), and each built
  string is kept (`MentionTextMemo`) by what it says and how each of its mentions shows, so a frame
  of texts that didn't change builds nothing: the 2,048 used last, and never one the frame being
  drawn has drawn, so a frame of more grows it, and it keeps what each editor's last frame drew
  (a cache of fixed size that a frame goes through in order would lose each text just before
  drawing it again). Where a frame ends is an overlay of Mentions' that draws nothing.
- **Where pills are.** `editor.mentionPills(of:)` is each pill's frame, in world units, with
  `isLive`, from the same placements, as string drawing puts them: a line that doesn't fit, or a
  pill the "…" of a cut-short last line covers, has none. The `MentionTexts` point (`x.mentionText`,
  `registrar.mentionText(K.self)` from a bridge, `registry.mentionTextPlacements(of:)`) is what the
  faces read.

### The service: `MentionState`

`MentionState` (`editor.mentions`) is what Mentions knows about a board, and never transacts (so it
follows undo and redo, during which nothing may):

- **The index**: who mentions whom, both ways (`mentioners(of:)`, `mentions(in:)`), and how each
  mentioned shape shows now (`resolve(_:)`), from mention text wherever a shape keeps it (a
  property, or a struct, list, set or dictionary in one: `forEachNamingLeaf`). It's built as a
  board opens, walking only the kinds that can hold names (`registry.namingKinds`), and each
  commit costs what it changed: the text of the shapes it added or changed is read again, and the
  mentioned shapes it touched are resolved again. A commit that only moved shapes costs nothing.
  Undo and redo are commits too, with exact change sets (`restoredStep`), so the state follows a
  step undone as any other: a rename undone gives every pill, row and editor its name back, and a
  deletion undone makes its pills live. A board opened again (`replaceDocument`) is read afresh,
  with nothing to undo.
- **Following changes**: `observe(_:_:)` tells an AppKit view which of its targets' resolutions a
  commit changed (the text view's pills), `labelRevision(of:)` observes one target for SwiftUI, and
  `rowsAffected(by:)` names the shapes that mention what changed, for rows: a note's row reads its
  text with live names (`context.plainText(_:)`), and names `MentionRows.affected` as its
  `affected:`, so a rename remakes only the rows of the notes that mention the renamed shape.
- **The catalog**, what the picker searches: every mentionable shape on the board but those kept
  aside, read again at the next query for the shapes a commit changed. `candidates(matching:in:for:)`
  lists, for an empty query, the recent picks (`didPick(_:)`) and the shapes nearest the text's
  shape (looked for in squares around it, grown until one holds enough, or holds as many shapes as
  the catalog, when reading the catalog costs less: a board with few mentionable shapes reads
  them), and for any other the best 50 matches. `MentionMatcher` scores the folded query (case and
  diacritics ignored) against each name, each taking its best tier: exact 1000, a prefix 800, each
  word a prefix of a word, in order, 600, a substring 400, a subsequence (fzf-style: word starts,
  runs and the first character count, gaps cost) at most 300, and, for a query of 4 or more that
  found fewer than 8 above, one typo (a Damerau edit of a word's prefix) 100; then recent picks and
  nearness add to the best, a placeholder name loses some, and ties go to the shorter name, then
  the shape in front. Two linear passes over the catalog's folded names and a heap: a keystroke at
  10,000 shapes, and the `@` that opens the picker among 10,000 of which 3 can be mentioned, are
  held to 2 ms.
- **Going and hovering**: `follow(_:)` goes to a shape on the next turn of the scheduler
  (`editor.goTo`: editing ends, the shape is selected and brought into view, and ⌘[ comes back;
  going is no undo step, so Undo after it takes back the edit before it, selecting what was
  selected then, and Back returns to where the mention went),
  since a click in the text being edited is still being handled by the view that going ends;
  `hover(_:)` and `endHover(_:)` set `editor.hovered`, so the shape is outlined faintly and its row
  tinted, the one hover every plugin shares.

### On the canvas: faces

A pill on the canvas is a [face](#faces-clickable-parts-of-a-shape): its shape's press, which
selects and drags the shape as any press does. Two planes, as text selection has them: the shape
is the note, and the text is its editor.

- **A click** on a pill edits its shape from the pill (`beginEditing(_:at:)` at the pill's
  center), and the editor selects the pill's character there: a pill is selected as text is, never
  followed on a single click. A read-only shape (a locked one) isn't asked to: a refused edit is a
  try to change it, which Locking shakes, and a click isn't one.
- **A double-click** on an editable note's pill lands in the text view the click opened, which
  follows it. On a read-only shape the canvas's face follows it (`goTo`). A missing pill's does
  nothing.
- **The pointer** over a live pill hovers the shape it names; over a missing one, its own shape.

Faces are Selection's, so a plugin list with Mentions needs `SelectionPlugin()` (and so
`KeyboardPlugin()`).

### Editing: `MentionTextView`

The note's editor is a `MentionTextView<AnyMentionable>`, an `NSTextView` on TextKit 2, with the
note's style, its shape as `owner` (never offered in its own picker) and the service:

```swift
textView = MentionTextView(frame: CGRect(origin: .zero, size: frame.size), text: text, style: NoteStyle.text,
                           owner: context.shapeID, mentions: context.service(MentionState.self))
if let start = context.startPoint {                             // begun from a pill: world units, the note at 0, 0
    textView.selectPill(at: CGPoint(x: start.x - frame.minX, y: start.y - frame.minY))
}

func textDidChange(_ notification: Notification) {
    let text = textView.mentionText                             // canonical, each pill named as it shows now
    context.update { if $0.text != text { $0.text = text } }    // a second report of one change writes nothing
}
```

- **A pill is one character.** The caret steps over it, a selection takes it whole, Delete takes
  it, typing replaces it. A click on it selects it; a double-click on a live one follows it
  (`MentionState.follow`), and on a missing one keeps it selected. Such a press is the view's to
  its release: its drags and its release never reach the canvas behind, which would take them for
  the pointer over it and hover the note. It's not a link: no pointing hand. Its menu adds Go to “Name” (a live one) and Remove Mention, which leaves its name as text.
- **Copy and paste** write the stored form under a type of the app's own (`.mentionText`) and the
  plain form ("@Ship the beta") as a string; a paste reads the stored form first, then plain text,
  where a whole `@[name](shape:UUID)` becomes a pill. So ⌘C and ⌘V on a pill make another mention
  of the same shape.
- **Live.** The view observes its pills' shapes and redraws the pills of those that change, with no
  edit and nothing committed. Each pill holds the name the board holds for it (as the text was
  last written, each pill named as it showed then), so a pill whose shape goes shows that name, as
  the canvas does, and nothing changes as editing ends or begins.
- **Undo.** While the text is edited, Undo is the text's own: a board's window gives Edit › Undo to
  the text that has the keyboard ([Undo](#undo)), and so does any window whose undo manager the
  text uses. Under TextKit 2 a text view's own undo and redo change its text without telling its
  delegate, so after either the view shows the pills it put back as their targets are now (renamed
  or deleted meanwhile) and calls `didChangeText()` if its text isn't what it last reported, and
  the host commits it. That's what writes an undo back in any window; a board's window also tells
  the text it changed after its undo, which finds the text reported, and the host commits only a
  changed value, so each undo writes once. Its steps go with it as it leaves its window, and only
  its own (its text's and its own actions): a board's window forgets its text's undo as the text
  loses the keyboard anyway, but any other window's undo manager outlives the editing view, so
  this keeps ⌘Z to what this editing did. For the board, the editing session, whatever it did
  (typing, picks, Remove Mention, pastes), is one step, which Undo takes back whole once editing
  is over: "Typing" when it began on a note already there (a click on a pill too), and one with
  the action that began it when there was one ([Undo](#undo): a note placed and typed into is
  "Add Note"); the board's Undo while the text is edited (from a plugin, or a host without a
  board's window) ends editing first.
- **Accessibility.** Every range is the text's own, a pill one character, so its value (with
  U+FFFC for each pill, as the text holds it), its count and its selection agree; the strings
  VoiceOver reads for a range, or the selection, say a pill as its name and kind ("Ship the beta,
  Task"), or why it isn't live ("…, deleted"). Writing Tools leave pills alone.
- **The picker.** `@` typed where a word starts (at the start, after whitespace or an opening
  bracket or quote, never in `name@example.com`) opens it: `textView.picker`, a `MentionPicker`,
  the picker's model, headless, shown in a child window that never takes the keyboard. What's
  typed after the `@` is the query: Recent and Nearby for an empty one, else the matches, the
  matched characters semibold; "No matches" or "Nothing to mention" when there's none. ↑ and ↓
  move, Return and Tab pick, Escape closes, and so do the caret leaving the query, a line break,
  a query longer than 80 characters (a whole title can be typed), or a space after a query that
  matches nothing. A pick puts the pill in the query's place, then a space, one step of the text's
  undo, which gives back the query as typed. Undo while it's open closes it: the text's, taking
  back the `@` typed, or the board's, ending editing. While it's open, the highlighted shape is hovered on the canvas,
  and autocorrection is off. VoiceOver hears its list change as the highlight moves (the row, or
  the empty state, said) and go as it closes (`MentionAccessibility`).
- **Where editing began.** `selectPill(at:)` selects the pill at a point in the view: the note
  calls it with `EditContext.startPoint`, so a click on a pill on the canvas has that pill
  selected in the editor, and a click anywhere else puts the caret where it always has.

A note's render and its editor lay the pills out alike: each pill's frame in the editor is the
canvas's (StickyNotesTests' `noteEditorTests`), so nothing moves when editing starts.

## The command line

`canvas` is the app's command line, for agents first and people too: it runs commands on the
boards open in the app, which must be running, and each change shows in the board's window as it's
made. Agents never read or write a board's file; they go through `canvas`, so the file stays the
app's to change.

```
canvas status                           whether the app is running: its version, protocol and boards
canvas boards                           the open boards: each one's id, name, file, and which is in front
canvas kinds [<kind>] [--schema]        the kinds of shape, what places each, and its properties
canvas create <kind> [--at <x,y>] [--size <width,height>] [--set <name=value>]... [--props <json>] [--board <board>]
canvas help [<command>]                 what a command takes (--format json: what the app says, schemas too)
```

Four modules, one job each:

| Module | Layer | What it does |
|---|---|---|
| CanvasRPC | wire | What the app and `canvas` say to each other: JSON-RPC 2.0, a message a line, over a Unix-domain socket (`~/Library/Application Support/InfiniteCanvas/canvas.sock`, or `CANVAS_SOCKET`) only this user can reach; what a command is (`CommandSpec`, its params a JSON Schema) and how its params are spelled as arguments; the client, and the listener. Knows no canvas, plugin or AppKit. |
| CanvasCLI | cli | `canvas`: reads its own options, asks the app what it runs (`describe`), reads the rest as one of those commands, runs it, and prints what comes back. Knows only the wire. |
| CanvasUI's `CommandServer` | ui | The app's end: it listens, describes the app, and answers each request on the main actor. `status` and `boards` are its own; it runs the rest on the board a request names (`--board`: an id, a file or a name), or the one in front. |
| Automation | horizontal | The commands plugins give the command line (`AutomationCommands`), and its own two, `create` and `kinds`. The app hands them to its server through Composition (`ShippedPlugins.commands(in:)`). |

**The commands are the app's, so `canvas` never changes for one.** It knows no command but `help`:
each run asks the app to describe itself, and makes its commands, their arguments and their help
from what comes back. A plugin that adds a command adds it to `canvas`, help and all, and the two
can't disagree about what a command takes. The app carries the `canvas` it was built with
(`Contents/Helpers/canvas`; `build/canvas` links to it), and `canvas` refuses an app that speaks
another version of the protocol (`RPC.protocolVersion`).

**A command is a name, its params, and what it does**, registered with Automation, as `create` is
([Commands.swift](../Sources/Automation/Commands.swift)):

```swift
struct CreateShape: SchemaDefined {
    static let properties = Properties<CreateShape>(title: "create") {
        Property("kind", \.kind).required().description("The kind of shape: one that `canvas kinds` lists.")
        Property("at", \.at).description("Where the shape's middle goes, in world units. Default: the middle of the board's view.")
        Property("set", \.set).keywords(["x-value-name": "name=value"])
            .description("A property to set: text for a property that's text (text=Hello), JSON for any other (estimate=3).")
        // size, props
    }
    var kind = ""
    var at: CGPoint?
    var set: [String] = []
}

registrar.automationCommand("create", "Put a shape on a board.", params: CreateShape.self, positionals: ["kind"],
                            examples: [CommandExample("canvas create <kind> --at 400,300", "…")]) { params, context throws(AutomationError) in
    let editor = try context.board()           // the board --board names, or the one in front
    // … the shape, from what the kind's tool places and what it's told …
    editor.transact { $0.insert(record) }      // as any change is made: it shows, and the board is edited
    return Created(id: record.id.description, kind: params.kind, …)     // anything Encodable, as JSON
}
```

- **Params are a list of properties** ([Properties](#properties)), whose JSON Schema is what
  `canvas` reads the arguments by: a string as it's typed, a number or an integer read as one, a
  boolean a flag (`--schema`, `--no-schema`), a fixed number of numbers (the core's point and size)
  as `x,y`, an array of any of those by giving the option again (`--set a=1 --set b=2`), and
  anything else as JSON (`-` reads it from standard input). Each property is an option (`fooBar`
  is `--foo-bar`), those in `positionals` also take their places in order, and help shows each
  one's `description`, its default, and what `x-value-name` calls its value. The app checks what
  comes against the schema and decodes it, so `run` gets its params typed.
- **A board command** (the default scope) runs on a board: `context.board()` is its editor. An app
  command (`scope: .app`, as `kinds` is) runs with the registry. `board` is the server's param, and
  `canvas`'s own options (`socket`, `format`, `timeout`, `help`, `version`) are `canvas`'s, so the
  registry refuses a command that declares one; a name the command line can't type (words of
  lowercase letters, digits and hyphens: `create`, `board list`) or one that's kept
  (`RPC.reservedCommandNames`: the protocol's `describe`, the server's `status` and `boards`,
  `canvas`'s `help`); a positional
  that isn't a param; and two commands of one name.
- **An error says why, and what to do**: `AutomationError(message, reason:, hint:)`, where `reason`
  is a word an agent can branch on (`unknown_kind`) and `hint` is often the command to run instead;
  a name that's nearly one gets a "Did you mean". `canvas` prints a result on standard output (JSON
  when that isn't a terminal, which is how agents run it, or text; `--format` says which), an error
  on standard error, and exits 0 when it's done, 1 when the app couldn't do it, 2 when the command
  line is wrong, and 3 when the app couldn't be reached.
- **A command changes a board as anything does**: through `editor.transact`, on the main actor, so
  the window shows each change, the board is edited and saves itself, read-only shapes refuse, and
  services hear the change set. Who made a change isn't recorded yet.

`create` uses two things the core lends a plugin that makes shapes without the pointer:
`registry.placement(for: kind)`, what the kind's tool places (`placement.size`, and
`placement.shape(at:)`, the shape it puts down with its middle on a point, in no document yet), and
`registry.shape(kind, properties:)`, a shape from its properties as one JSON object, own and added
side by side as its kind's schema describes them: the inverse of `record.propertiesJSON`, but for
what a kind derives from the rest (`DerivedProps`: a schema card is as tall as its schema, as its
panel would make it). So it
starts from what the kind's tool would place (a task's "New Task" title with it), sets what it's
told over that (`--props`, then each `--set`: as typed for a property that's text, as JSON for any
other), and inserts it. A shape past its schema's bounds is made, with a warning, as the app makes
any; a kind no tool places (an arrow, a line) starts from the properties it's given. What a shape's
props are bound to (an arrow's ends, through `ShapeReferencing`) must be on its board: a shape bound
to one that isn't would stay bound to it, and nothing would let go, so `create` refuses it and says
which (`A tag can't be bound to shapes that aren't on this board: …`, hint: bind it only to shapes on
the board the command works on).
That's what the shape is bound to (`record.boundShapes(in:)`). What it only names
([`ShapeNaming`](#values-that-name-shapes), a mention) may be gone, as it may once the shape it
names is deleted: the shape is made, and a warning for each property that names shapes not on the
board says which (`lead names shapes that aren't on this board: …; they show as missing.`).

The app that holds the socket's lock (`canvas.sock.lock`, beside it) is the one listening: a second
copy of the app gives up and runs without the command line, and a socket that one that crashed left
behind is taken over. A command's options may also come before its name (`canvas --board 2 create
ellipse`), as agents often write them.

## Schema cards

Schemas ([`Sources/Schemas`](../Sources/Schemas)) is a vertical whose shape is a JSON Schema: a
`SchemaCard` (kind `schema-card`; `frame`, `schema`, `prompt`), placed empty with the Schema tool
(S). The schema is kept as **text**, not a parsed value: a dictionary would lose the order its
properties were written in, which the card shows, and a schema being typed isn't JSON for a while.
Nothing restricts what it says; the card reads the keywords most schemas use, and the rest stays in
the text. Its name is its own root `"title"`, so there's one place to say it: a title Titles
derives (`schema.title(pill: false) { … }`), never the `TitleProperty` Titles keeps for notes and
tasks, so the kind's schema has no `title` of its own; `setTitle` rewrites just that member. The
card draws its name inside, as a task card does, so Titles places no pill ([adornment](#adornments))
on it; what other plugins show on shapes still shows on it (a locked card's lock, at the right end
of the row above).

```swift
registrar.service { SchemaSync(editor: $0) }                                           // below
registrar.shape(SchemaCardDefinition()) { schema in
    let place = schema.placement(size: SchemaCard.defaultSize) { SchemaCard() }        // 240 × 67, empty
    schema.tool(label: "Schema", systemImage: "curlybraces", shortcut: "s", placing: place)
    schema.validate { shape, _ in SchemaReadings.reading(of: shape).issues }
    schema.title(pill: false) { SchemaReadings.reading(of: $0).shown.title }
    schema.contentsRow { shape in ContentsLabel(…, systemImage: "curlybraces", badge: "6") }  // top-level fields
    schema.schemaPanel()                                                               // the header and the Schema tab
    schema.schemaLinks()                                                               // ports: a schema to a schema
}
registrar.channel(SchemaLink.self)
```

- **Reading.** `JSONReader` is an order-preserving JSON reader: every object's members in order,
  every value and key with its range (UTF-8 offsets), errors with a line and column a person counts,
  tokens for coloring, and no text that crashes it (it refuses nesting past 256). `SchemaDocument`
  reads a schema from it: its title (even from a half-typed text, if the root's `"title"` came
  first), its top-level fields (`properties`, then `patternProperties`), and the rules at its root
  (`if/then`, `allOf`, …). A `SchemaField` reads its type (`SchemaFieldType`: `format` in place of
  `string`, `enum`, `const`, `$ref`, `oneOf`/`anyOf`/`allOf`, type lists, boolean schemas, arrays of
  anything, and a type that isn't one of JSON Schema's seven as written, `unknown("ninteger")`,
  never `any`) and its own fields a level at a time, following `$ref`s within the document, each
  step bounded, so a `$ref` in a circle ends.
- **The card** is the schema's overview: a row per top-level field, at most 7, its name in a chip
  (a gray `*` if required, after the name even when it's cut short, `…*`: the card's one hue is its
  `{}`), then what's in it (an object's fields in braces, an array of objects' in brackets,
  anything deeper `{…}`; an enum's values or a choice's options between bars), and its type at the end, in JSON Schema's words (`oneOf`), unless the tray
  already says it (braces, bars); a label with no room says the type in a word (`array`, `string`)
  before it's cut. A tray that could say only how many it holds (`{ 4 fields }`) never cuts the
  name short: the name gets the room. Nested fields never take a row, so they never count toward
  the cap: 8 fields or more show 6 and `+N more`, then `Rules if/then · allOf`. A card with none
  says so in one muted line where the first row would be ("No fields"), and nothing else: no box,
  no advice. `SchemaCardLayout` decides all that for a size (tests read it, and
  `SchemaCardLayout(card)` is what a card shows now); the definition draws it. The height is the
  content's, set in the same transaction as the schema: `setSchema` sets the text and
  `SchemaCard.height(for:)`, 45 and 22 a row, at least one (67), arithmetic with no fonts; a text
  that isn't a JSON object (not JSON, or `[1]`) leaves the frame alone, so it still fits the last
  reading the card shows (below). The width is the person's. An untitled card is
  `SchemaCard.untitled` ("Untitled") on the card, in its header and in its row.
- **Cost.** A card's text is read once: `SchemaReadings` keeps a reading per card (and its
  layouts), compared with the card's text by identity (the record's own string) before anything,
  and read again only when that text changes, so typing replaces one reading and a frame parses
  and measures nothing, however many different schemas are in view. Readings of deleted cards, and
  of cards on a board read again, are dropped (the sync hears it), and past 4,096 the quarter used
  longest ago; debug builds count
  reads (`SchemasPlugin.schemasRead`). Far out, rows, `+N more` and the rules are bars (below
  35%), then the title (below 20%); a line saying there are none isn't a field, so no bar stands
  for it. A card made from properties (`canvas create`) is as tall as its schema (`DerivedProps`).
- **Typing through a broken text.** A keystroke in the middle of a member leaves the text not JSON
  for a moment, so while a card's text isn't a JSON object, what it shows stays what its last one
  that was said (`SchemaReadings.shown`, kept this session, and dropped with the card, or when its
  board is read again from disk, since it's in no version of the file): its rows and name on the
  card, its row and badge in the table of contents, its title, its panel's header. The card
  doesn't flicker; Validation's red outline says it's broken. What acts on the text reads the text
  itself (`document`): Validation's rules, the sync, the editor's colors, a rename. A card that
  was never a JSON object since its board was read (opened so) says why in the "No fields" line's
  place: "Invalid JSON" or "Not an object", muted, never red.
- **Rules.** A text that isn't JSON is an error at its line and column ("Invalid JSON: expected a
  property name at line 6, column 34."), as is a root that isn't an object; `required` naming a
  property its object doesn't have is a warning, as is a `type` that isn't one of JSON Schema's
  ("“ninteger” in birthYear isn’t a JSON Schema type.").
  Validation's own rule checks a card against its kind's schema, as it does every shape: `schema`
  and `prompt` are strings without bounds, so no text breaks it.
- **Ports.** As notes and tasks do, a card has ports on a channel of its own: `SchemaLink`
  (`schema-link`, the card's accent), on all four sides, since the card draws its name inside
  ([SchemaLinks.swift](../Sources/Schemas/SchemaLinks.swift)). A schema links only to a schema,
  and the link says nothing more yet.
- **The panel** is the card's only editor. Its header is a `TitleHeader` over the root `"title"`,
  with the field count the card shows under it ("6 fields"; nothing where it shows none). Renaming
  rewrites that member alone, so it can't while the text isn't a JSON object (the name shows, at
  full strength, as text: `isRenamable: false`), and while the model writes the schema it's dimmed.
  Its Schema tab has the **description** (the `prompt`, a `DetailTextArea` that commits; while the
  schema is an object with no fields, its placeholder is an example, "e.g. a pet in my household";
  none while it isn't an object, which nothing syncs from) over the **JSON** (a
  `DetailCodeEditor`, colored by `JSONReader.tokens`, the token where it stops being JSON
  underlined), and under the JSON what Validation finds, a status line each, in its words and
  tone (the line and column say where, since lines don't wrap). The sync's status shows under the
  side the person edited (`SchemaSyncStatus.source`), where they are and in view whichever section
  is collapsed: "Updating schema…" under the description, "Updating description…" under the JSON,
  with a spinner, or why it failed, in a fragment ("Anthropic overloaded", "Unusable answer"), in
  the warning's tone (red is the schema's own errors), with what to do
  (`SchemaSyncFailure.remedy`): Retry; Open Settings… alone, for want of a key, since saving one
  tries again by itself (it sends `AnthropicSettingsView.showSettingsAction`,
  `BoardMenus.showSettings`'s selector, up the responder chain for the app to answer); nothing
  (`editByHand`), for a schema too long to rewrite, or one cut off (`SchemaSync.tooLongMessage`).
  The side being written is read-only and dimmed. The sections' commits hold the sync weakly: a box
  that loses the keyboard as its window closes commits after the board has gone.

### Keeping the description and the schema in step: `SchemaSync`

Edit the description and Claude rewrites the schema; edit the schema by hand and Claude rewrites the
description to say what it now holds. `SchemaSync`, the plugin's service, does it per card, through
`editor.languageModel`:

- **When.** Only the person's edits to the two sides start a sync: never its own write, a board
  read again from disk (a revert, a reload; `ChangeSet.replacedDocument`, whose cards are seen for
  the first time, with their calls and timers dropped), or a change to anything else about the
  card (a move, a lock, a restack). A commit (Return in the
  description, ⌘↩ in the schema, the keyboard leaving either) syncs at once; otherwise it's
  `SchemaSync.idleDelay` (3 s) after the last keystroke, on `editor.scheduler`.
- **Which way.** The description changed (and isn't empty): the schema is written from it, the
  model told the description at the last sync, so what was deleted from it is removed. Else the
  schema changed in meaning (a reformat or a reorder doesn't count): the description is written from
  it, told the schema at the last sync. Both: the schema, from the one edited by hand. The schema is
  written whole however small the edit, so one past `SchemaPrompts.toSchemaMaxLength` (34 KB, which
  might not fit the answer's 16,000 tokens) is never sent: the status says it's too long to
  rewrite, with no Retry, and once the person edits it by hand, the description is written from
  that edit.
- **Never** while the schema isn't a JSON object (someone's halfway through it, or it's blank), for
  a read-only (locked) card, for a new card with no fields and no description, for a description
  cleared (it says nothing about the schema) or only respaced, or without a model. A card seen for
  the first time (on a board opened or read again, pasted, placed) is taken as in step: that pair
  is its last sync, which the model is told as it would be one made this session (so a field taken
  out of an opened card's description is taken out of its schema; the prompts' contract leaves the
  previous side out of a card opened, which would only add). All but a description over a schema
  that's JSON with no fields: that was never answered (the call failed, or the board closed first),
  so its description is ahead, and the next commit asks for the schema from nothing (nothing syncs
  on opening).
- **While a call is out** the side it writes is read-only, and the status says so. If it changes anyway
  (by a plugin, a test), the answer is dropped; edits to the other side wait for it: they sync
  when they're committed or 3 s after the last, as ever, or as soon as it lands if either came
  while it was out; a card deleted or read again meanwhile drops it; a card locked meanwhile gets
  nothing written (nothing is tried, so nothing's refused) and its pair stays as it was, so its
  edit syncs once it's unlocked. A failure leaves both sides as typed and says why, with Retry (the
  next commit tries again too; a key saved in Settings retries the cards that failed for want of
  one, `languageModelKeyDidChange`); a cancelled call says nothing; `NO_CHANGE` writes nothing and
  makes the pair in step. A
  schema is written as the model wrote it, never laid out again (its order is the model's, which
  keeps the person's; the prompt asks for two spaces, a member per line, plain arrays on one line),
  with `setSchema`, so the card fits it; the write is the sync's own, and starts none.
- **Undo.** Typing in either side, or renaming the card, is one step a run ("Change Description",
  "Change JSON", "Change Schema"), and the sync's write is one of its own ("Update Schema",
  "Update Description"), taken with the pair it leaves in step (`undoHistory.group`). Undo and redo
  are no edit: their commit is marked `ChangeSet.restoredStep`, so they start no sync, and a card
  whose sides they change drops its timer and any call out (the answer would be to what the card
  no longer says), its status idle. The pair at the last sync goes back and forth with the steps
  (`SchemaSync` is an `UndoParticipant`, its pairs a dictionary apart from the rest, copied on
  write): undoing the sync's write leaves the card as before the answer, its description ahead of
  its schema, until the person edits or commits it, when the model is asked as it was the first
  time; redoing it leaves the card in step; a card's deletion undone brings back what it last
  synced, so a description typed since is still ahead. Only the cards a step brings back or
  changes the sides of get their pair back: another card keeps what its sync learned since (a
  `NO_CHANGE` that landed while another shape moved), which undoing the move doesn't change.
- **What it asks** is `SchemaPrompts`: the two system prompts (raw string literals, each its text
  byte for byte, which [`scripts/schema-prompts/evals.py`](../scripts/schema-prompts) reads out of
  the Swift, so the quick evals test exactly what ships), the user message (tagged blocks, each
  trimmed: `<previous_prompt>`, `<prompt>`, `<schema>`; or `<prompt>`, `<previous_schema>`,
  `<schema>`; empty ones left out, tags and all), 16,000 tokens at most for a schema and 2048 for a
  description, temperature 0, no prefill or stop sequences, and `parse` (the answer trimmed, then
  unwrapped of any code-fence line and its own block's tags, from either end, until none is left:
  the model sometimes adds them though the prompts ask for neither; a stop other than the end of its
  turn is a failure, as is a schema that isn't a JSON object from its first character to its last,
  said in three fragments: a schema cut off is too long to rewrite, a refusal is "Claude declined",
  and anything else an "Unusable answer", as `LanguageModelError.malformedResponse` says it;
  an answer whose first word is `NO_CHANGE` is no change, whatever follows it, and so is one whose
  last line is; a line of a tag alone at either end, `</output>`, is dropped; a description loses
  one pair of quotes around it, and isn't written if it reads as something else: `NO_CHANGE` inside
  it, a fence, a preamble such as "Here's the updated prompt:"). The system prompts treat what the
  other side holds as data (a description in the schema that reads as an instruction is kept, never
  followed), name new properties in the prompt's language (plain ASCII for one written in Latin
  letters, its own script for any other), and count a field given by `$ref` as required only where
  its own object's `required` names it.
  `editor.schemaSync?.status(of: id)` is observed a card at a time, so a card's panel redraws for
  its own sync only; the panel's sections read it through `$card.service(SchemaSync.self)`.

## Language models

LanguageModels ([`Sources/LanguageModels`](../Sources/LanguageModels)) is a horizontal that declares
no extension point: it lends every editor one language model, `editor.languageModel`, for any plugin
to ask, and knows nothing of what they ask it for.

```swift
guard let model = editor.languageModel else { return }      // nil without LanguageModelsPlugin
let request = ModelRequest(system: "Answer with JSON only.", messages: [.user(prompt)], maxTokens: 2000)
do throws(LanguageModelError) {
    let response = try await model.respond(to: request)     // response.text, .stopReason
} catch {
    status = error.message                                   // "No API key"
}
```

- **The protocol.** `LanguageModel` is one async call: a `ModelRequest` (a system prompt, the
  conversation as `ModelMessage`s, `maxTokens`, `temperature`, `stopSequences`) in, a
  `ModelResponse` (its text, `stopReason`, token counts) out, or a `LanguageModelError` (no key,
  unauthorized, rate limited, overloaded, another status with the service's message, the network, a
  malformed answer, no answer in time, cancelled), each with a short `message` for a person and
  `isTransient` for whether trying again later may work. A message names what went wrong in a
  fragment, never what to do about it, which the button beside it says: "No API key", "API key
  rejected", "Rate limited", "Anthropic overloaded", "Anthropic error 500", "Can’t reach
  Anthropic", "Timed out", "Unusable answer"; a request the service refused (a 4xx) is its message's
  first sentence ("Your credit balance is too low to access the Anthropic API"), with the key taken
  out, were it ever in it. Cancelling the task asking throws `.cancelled`.
- **The app's model.** `AnthropicModel` calls Anthropic's Messages API from the app, with
  URLSession (no SDK, no streaming, no retries), Claude Haiku 4.5 by default. Nothing streams, so
  the answer comes whole, all at once: it waits a minute, and a second more for every 100 tokens
  the request may write (`timeout(for:)`: 16,000 wait 220 s; Haiku writes some 150 a second), and
  throws `.timedOut` past that. It reads the key at every call, so a key saved in Settings works at
  once; Save and Remove in Settings post `Notification.Name.languageModelKeyDidChange`, so a plugin
  whose call failed for want of a key can try again by itself.
- **The key.** `AnthropicKeyStore.standard` is
  `~/Library/Application Support/InfiniteCanvas/anthropic-api-key`: the key and nothing else, mode
  0600, written whole and renamed into place; a missing file is no key. Not the Keychain: the app
  isn't signed, so each build would be a new app to it. Infinite Canvas › Settings… (⌘,) shows
  `AnthropicSettingsView` (a secure field, "Anthropic API key", whose prompt says whether one is
  saved and whose tooltip says where; Save, Remove, and Test, a five-token call; a status only for
  a test and for what failed, a symbol in its tone then the words, as the panel's status lines are,
  a failure in the warning's tone, as the panel shows the same failures; and a link, "Get a key"),
  which Composition hands the app as `ShippedPlugins.settings()`, in its `SettingsWindow`: made
  afresh each time the window opens, and sized before it goes in, so the window opens where it was
  left. A test that can't save the key typed stops there, a test's outcome reads again whether a
  key is saved (its file may have gone meanwhile), and Remove waits for a test to finish. A plugin that finds no key offers to
  open it: `AnthropicSettingsView.showSettings()` sends `showSettings:` up the responder chain,
  which the app's delegate answers (the same selector as `BoardMenus.showSettings`).
- **Tests** pass a `ScriptedLanguageModel` ([Testing plugins](#testing-plugins)), never the network.

## Capabilities

Some behavior belongs to a kind itself rather than to a concern others can join. That's a
**capability**: a protocol refining `ShapeDefinition`, found with `as?` by the module that declares
it, the core or a horizontal.

| Capability | For | Used by |
|---|---|---|
| `Editable` | Edited in place: an editing placement, or Selection's double-click and Return. Supplies an `NSView` laid over the shape; writes go through `EditContext.update`. | StickyNotes |
| `CustomTranslation` | Moving by its own rules instead of by its frame, when a `TranslatingSession` moves it (dragging the selection, a shape just placed). When a drag starts, `beginTranslation` gets the shape, every shape moving with it and the starting transaction (committed on its own, before the first move), and returns a `ShapeTranslation`: a closure run on every drag event with the pointer's delta, after the moving boxes have moved. A kind without a frame needs this to be movable at all. | Arrows (alone, bound ends slide on their shapes; with a shape they're bound to, they keep every binding); Polylines (every point by the delta) |
| `HandleProviding` (Selection's) | Draggable handles on the only selected shape. The select tool finds, draws and hit-tests them; `pressHandle` returns `.drag` or `.consumed`, and `dragSession` does the dragging. | Arrows |
| `BrushHitTesting` (Selection's) | Whether the marquee touches it, when the brush overlaps its bounds without containing them. Default: `ShapeGeometry.isHit(byBrush:)`. | Arrows (against the visible arc) |
| `DerivedProps` | Props that hold something following from the rest, which the kind's setters keep in step. A shape made from properties written somewhere else, `registry.shape(_:properties:)` (the command line's `create`), goes through `derive(_:)` first, so it's as its setters would have left it; a board read (a shape is as saved), a paste, and what a person does don't. | Schemas (a card's height, from its schema; `--size` still wins) |
| `PaintOrderAnchored` | Painted just above another shape, whatever its place in the document. The anchor follows from the shape's own props and the document's order, since the paint order is kept until one of those changes. | Arrows (above the shapes they join) |
| `ShapeReferencing` | Props bound to other shapes: every kind whose props are adopts it, or it stays bound to a shape once it's gone. `remappingReferences(of:_:in:)` passes each through a map: bound to the shape it gives, or, for nil, let go of where it's drawn. Deleting a shape asks it of every shape bound to it (after `willDelete` handlers, before anything's removed), and copying asks it of each copy (`record.remappingReferences(_:in:)`). It returns nil when it can't let go of a shape it can't find: a deletion leaves it as it was, and a copy leaves it out. These are bindings, which must be on the board; a name that may outlive its shape (a mention) is a value instead, [`ShapeNaming`](#values-that-name-shapes). | Arrows (an end lets go where it's drawn, keeping the curve; a copy stays bound to the copies of its shapes); CanvasTesting's `Tag` |

The rule of thumb: behavior intrinsic to a kind is a capability; behavior anyone can add, to any
kind, from any plugin, is an extension point. What a kind shows in the detail panel is an extension
point, not a capability: the kind's own plugin, a horizontal it opts into, and a bridge can all add
to it.

An editing view's `EditContext` is its way back into the editor: `update` changes the shape in a
transaction, and `end()` ends editing. `service(_:)` lends it the editor's services (a completion
list's candidates), as the detail panel's, the table of contents' and adornments' contexts do.
`startPoint` is where the press that began editing was, in world units, when whatever began it said
so (`editor.beginEditing(id, at: point)`), for the view to put its selection there (the character
pressed); the editor keeps it as `editingStartPoint` while editing lasts. Return, Selection's
double-click and a placement say nothing, and the view chooses, as it always has.

## The editor, the document, and drawing

- **The document is a value.** `CanvasDocument` holds every shape, back to front, in the order of
  their stacking keys: each record carries its own (`stackingKey`, a fractional index as in
  tldraw), so moving a shape in the stack changes that shape alone. The only way to change it is
  `editor.transact { tx in ... }`: `insert` (on top), `update` (typed with `as:`; it can't change a
  shape's id or key), `bringToFront`, `sendToBack`, `move(_:above:)`, `move(_:below:)`, `delete`,
  `translate(_:by:)`, which moves shapes as dragging them would, and `moveBox(_:to:)`, which puts
  a box where a drag does. A record carries its props, the
  values of its [added properties](#added-properties) and its [metadata](#metadata), and
  `record.copy(as:)` is the same shape under another id.
  A transaction commits once, if anything changed, and bumps `editor.revision`. What it did goes
  with it, record by record: its `ChangeSet` names the shapes it added, changed and removed, and
  of those changed, the ones it only moved (`moveBox`, as a drag and `translate` do, and nothing
  else), and says whether the stack changed. Transactions don't nest. A frame that isn't finite never gets in: such an insert or update is dropped, since a board
  must always save. An added value the shape's kind can't hold is dropped too, and an insert fills
  in the defaults of what its kind opts into. A read-only shape (a locked one,
  `registrar.readOnlyShapes`) keeps whatever a transaction does to it, unless the change leaves it
  no longer read-only, and services hear it was refused ([read-only
  shapes](#the-cores-part-read-only-shapes)). Every commit goes into an [undo step](#undo)
  (`editor.undoHistory`): everything from a press to its release, a key, a command or a group is
  one step, and so is everything while a shape is being edited; `transact("Move")` names it, and
  `editor.undo()` and `editor.redo()` put a step's records back exactly.
- **`willDelete`** handlers run inside the deleting transaction, before anything is removed, and
  see every shape as it was, so a plugin can act on shapes about to disappear (delete what depends
  on them). They may delete more, and change what they must, read-only shapes included; each
  shape's handlers run once. Then every shape bound to one of them, and stays, lets go of it, as
  its kind's `ShapeReferencing` says (arrows bake their curve there). Names of them
  ([`ShapeNaming`](#values-that-name-shapes), a mention) are never looked at, and stay.
- **Lookups.** `editor.shapeContext` looks up the editor's shapes (and keeps their geometry from
  frame to frame), `transaction.shapes` a transaction's as it is so far, and
  `ShapeContext(document:registry:)` a document of your own (what's on the pasteboard).
  `bounds(of:)` is the union of shapes' geometry: what boxes a selection, or brings shapes into
  view.
- **The hint** (`hintedShapeID`, a target outlined whatever the tool) always names a shape that
  exists, and so does `editingShapeID`, the shape being edited. After every transaction that
  changed the document, services hear `documentDidChange` with its change set: they drop what's
  gone (the selection does), and redo what they keep per shape for just those shapes (validation
  does). `replaceDocument` (a board read again: a revert, a reload after the file changed on disk)
  sends one too, marked `replacedDocument`: its shapes are as saved, not as anyone changed them, so
  a service that acts on edits takes them as shapes seen for the first time (the schema card's sync
  does). Undo and redo send theirs marked `restoredStep`: the shapes are as a step began or ended,
  so such a service follows none of it as an edit, and puts back what it kept as it was then, as an
  [`UndoParticipant`](#undo). What's selected is [Selection's](#selection).
- **What the editor keeps.** Each shape's geometry and extent (its geometry's bounds, with its
  box), and the paint order, from one frame to the next, so a frame costs what's in view and what
  changed rather than what's on the board. A shape's geometry is kept until the shape changes or a
  shape its definition looked up through its `ShapeContext` does. The paint order is kept until
  the stack changes or an anchored shape's anchor does, which is why an anchor follows from the
  shape's own props and the document's order. `editor.shape(at:)` asks a shape's `hitTest` only
  about points within its extent grown by its `hitMargin`, and `editor.paintOrder(in:)` is the
  paint order of just the shapes that may show in a world rect: what drawing goes through, and
  overlays too, with `context.visibleRect`. Code that runs per frame doesn't go through every
  shape; `./build.sh bench` holds a hover and a drag at 10,000 shapes to a frame (16 ms), with the
  minimap drawn too, and the table of contents' rows after a commit to a millisecond. The editor
  also keeps the bounds of every shape, and where each commit moved or reshaped shapes (its
  damage: where the shapes it touched were and are, with every shape whose geometry followed
  them), for a picture of the whole board kept from frame to frame, the minimap's, which redraws
  only that. Damage says where shapes are, not which is on top: a restack names the shapes it
  moved in the stack, not one it carried along above its anchor. It's host API (`shapeBounds`,
  `damageMark`, `damage(since:)`, and `outlines`, what the canvas outlines), as the minimap is
  the host's.
- **Drawing**, back to front: background and grid; shapes in paint order (culled by extent: those
  more than 40 world units out of view don't draw, and a shape with no outline always does), each
  where it's drawn ([`setDrawingOffset`](#the-cores-part-drawing-offsets): a shaking shape, away
  from where it is, with its outline); every
  plugin's outlines (`registrar.outlines`: selection, the box around several; none while the
  session `hidesOutlines`) and the hint, in one stroke at a constant screen width, over the faint
  ones (`Outlines.faintShapes`: the hover), stroked first, wider and lighter; world overlays;
  the running session's `draw(in:)` (the marquee); view overlays (Selection's handles first). Each
  shape, overlay and session draws with a fresh graphics state. Sizes meant as view points are
  divided by `zoom` in world space.
- **The camera** is `editor.camera`, which anyone may set; setting it stops any camera motion
  running. `editor.animateCamera(to:duration:)` moves it there, eased (tldraw's cubic), a frame
  every 16 ms, and `Camera(fitting:in:inset:maxZoom:)` (Geometry) makes one that shows a rect.
  `editor.cameraTarget` is where an animation is headed while it runs, else the camera: what to
  remember a view as mid-motion (Selection's steps back do).
  `editor.viewportSize` is the view's size in view points, zero until it has one.
- **The view.** `CanvasView` (CanvasUI) is the only AppKit in the loop. It converts events, reports
  its size, hosts the editing view over its shape, hands AppKit the menu for a secondary click, and draws the editor, all through the editor's `@_spi(Host)`
  API. It also hosts the minimap, in its bottom-left corner (`showsMinimap`; View › Show Minimap):
  every shape as a silhouette of its geometry, the part of the board the canvas shows outlined,
  and the selection in the accent color. It moves the camera as tldraw's minimap does, and knows
  no shape or plugin. Only the app and tests can import CanvasUI, and no plugin can see the host
  API, so no plugin can reach around the editor.
- **The views the canvas hosts have the pointer where they are.** Over the minimap or the editing
  view the pointer isn't over the canvas, though AppKit tells the canvas it moved (its tracking
  area covers them): the tool hears it leave (`pointerExited`), once, as it moves there or is
  released there (the press that began editing: a double-click, or a click on a face that edits
  its shape), and nothing more until it moves
  back onto the canvas. So the select tool hovers no shape under them (over a note's text,
  `editor.hovered` is only what another plugin sets, a table of contents row's), and
  `editor.pointerOverCanvas` is nil there (a note being edited hides its port dots while the
  pointer is over its text). The canvas leaves their cursor alone meanwhile. Once editing ends,
  where the editing view was is the canvas again, for the next move.

## Undo

Undo is the core's ([`UndoHistory.swift`](../Sources/Canvas/Editor/UndoHistory.swift),
[`CanvasEditor+Undo.swift`](../Sources/Canvas/Editor/CanvasEditor+Undo.swift)), since every change
already goes through `transact`: each commit is recorded, as the records it touched were before it
and are after, into the step it's part of. A plugin does nothing to be undone. It only names its
steps, and says what one gesture is when the editor can't see it. It's tldraw's model, not
`NSUndoManager`'s: a board's history is its editor's (`editor.undoHistory`), one per board file.

**A step is one action.** Commits go into the step that's open, which opens with the first of them:

| What | Its step |
|---|---|
| A press on the canvas: from the press to the release, its whole drag (a place and its follow or editing, a translate, a handle, a lock chip's click) | One. |
| A key on the canvas; a command (`editor.perform`: every menu item's, ⌘Z's and Delete's); `editor.undoHistory.group("Name") { ... }` | One each. These actions nest; the outermost is the step. |
| An editing session (a note typed into): its view's commits (`EditContext`) until editing ends, with what the view saves as it closes | One, "Typing"; with the action that began it, if one did (placing a note and typing into it are one step, as tldraw's one mark). |
| A run of commits under one key at no action's depth: `transact(coalescing: key)` (a panel field typed into, a slider dragged) | One, until another commit, an action, or `editor.undoHistory.seal()`. |
| Any other commit | One. |

Any other commit while a shape is being edited closes the editing step first; an action that
commits nothing of its own (Undo itself) leaves it open, so Undo, from a key or a menu, ends editing
and undoes the whole session, what the view saves as it closes included. Opening a step clears
what there was to redo. A step whose records all end where they began (a drag put back with Escape,
an arrow drawn and cancelled, a field typed into and undone) is dropped, and so is a transaction
all of whose changes were refused: nothing's recorded. Selecting, hovering, the camera and Go Back
aren't changes, and make no step.

**Naming.** A step takes its outermost named group's name, else its first named transaction's
(`editor.transact("Move") { ... }`), else "Typing" for an editing step; Edit › Undo shows it
("Undo Move"), or plain "Undo"; while the open step has come back to where it began, Undo names,
and undoes, the step before it. The core names placing ("Add" and the placing tool's label, "Add
Note"), moving ("Move") and typing; Selection "Delete"; ContextMenus every item by its title;
Clipboard "Cut" and "Paste"; Locking "Lock" and "Unlock"; Arrows "Add Arrow", "Move Arrow End",
"Bend Arrow" and "Toggle Arrowhead"; the eraser "Erase", polylines "Draw Line"; the detail panel
"Change" and the section's title ([`ShapeBinding`](#reading-and-writing-shapebinding)); the schema
card's sync "Update Schema" and "Update Description", however long after the edit it lands. Name a
transaction a user would think of as one thing, and wrap several in `group` when they're one action
the editor doesn't already see as one.

**Undoing** (`editor.undo()`, `editor.redo()`; `canUndo` and `canRedo`, false while a press's
session runs) ends editing, closes the open step, and puts back the step's records exactly: ids,
kinds, props, stacking keys (so the order), metadata, added and kept values, shapes kept aside. It's
exact because every commit is recorded, one step is open at a time, and steps come back last in,
first out, so the document always holds what a step left. It's applied as an ordinary commit with
an exact `ChangeSet`, so services hear it (`documentDidChange`: the index and the minimap's damage,
the table of contents, validation, locks), but it isn't a transaction: nothing's refused, nothing
shakes, and it's below the read-only rule. A locked shape goes back as it was too: undoing Lock
unlocks it, and a locked arrow that let go of a deleted shape binds again. So no service may
transact in `documentDidChange` (it would be a precondition failure while undo applies). The camera
never moves, as in tldraw.

**What else goes back.** A service whose state belongs with the steps adopts `UndoParticipant`: its
snapshot is taken as a step opens and as it closes, and undoing restores the first, redoing the
second. Selection's is the selection, as tldraw's: undoing Delete brings the shapes back selected,
undoing a move leaves them selected, undoing a paste selects what was before it. The restore is an
ordinary change of the selection, so Go › Back returns to what was selected before the undo.
A service that acts on edits tells a step put back from an edit by its change set's `restoredStep`,
and follows none: the schema card's sync keeps, as a participant, the pair of sides each card last
synced, and starts no call for an undo ([`SchemaSync`](#keeping-the-description-and-the-schema-in-step-schemasync)).

**Keys and menus.** The core claims the `.undo` and `.redo` commands (its plugin's, as Hand is),
Keyboard gives them ⌘Z and ⇧⌘Z (`registrar.shortcut(chord, forCommand:, repeats: true)`, held again
and again), and Edit › Undo and Redo run the same commands. The host splits them with text: the
board's window (`BoardWindow`, CanvasUI) answers `undo:` and `redo:`, and while text has the
keyboard (a note being edited, a panel's field) they're the text's own, through the window's text
undo manager (or a field's), never falling through to the board; once the text loses the keyboard
what it could undo is forgotten, and the board's step for the typing is what's left. Anywhere else
(the canvas, the table of contents' list, a checkbox) they're the board's, named. The window seals a
run on a click, on a key where neither text nor the canvas has the keyboard, and when the keyboard
moves, since the editor sees none of those; and every board's window seals on a click in a window
that isn't a board's (the color panel a color well opens, whose picks are panel writes).

**Counting and saving** is the host's: `BoardDocument` has no undo manager, and counts its changes
by the history's events as they happen (`undoHistory.didChange`, host API: a step began, came to
nothing, was undone or redone), so undoing to what was saved reads unedited, and past it edited. A
save closes the open step (`breakStep`) before NSDocument takes the change count it marks saved, so
undo goes back to exactly what was saved, and a step that comes to nothing as it closes leaves the
board unedited; a periodic autosave during a press waits for its release, and is scheduled again
then ([Boards on disk](#boards-on-disk)). A new document, a board opened or reverted
(`replaceDocument`) has nothing to undo.

**Once a file holds several boards**, a step will say which board it's on, and undoing one from
another board shows it first: `DocumentDelta` is the one type that holds records before and after
(it'll carry the board, and whole boards added or removed), and `CanvasEditor.apply(_:restoring:)`
the one place a step is applied. Agents and sync can reuse it, with who made the change.

## Boards on disk

A board is a file (`.canvasboard`; `.board` is Freeform's), one per board, opened and autosaved in place by `BoardDocument`
(CanvasUI, an `NSDocument`). `BoardCodec` (Canvas) reads and writes it: JSON, sorted and
pretty-printed, so a board diffs cleanly.

```json
{
  "format" : 3,
  "shapes" : [
    { "added" : { "checklist" : [] }, "id" : "…", "index" : "a0", "kind" : "sticky-note", "props" : { "frame" : [[80, 80], [200, 200]], "text" : "…" } },
    { "added" : { "checklist" : [ … ] }, "id" : "…", "index" : "a1", "kind" : "sticky-note", "meta" : { "clipboard" : { "copiedFrom" : { "shape" : "…" } } }, "props" : { … } },
    { "id" : "…", "index" : "a2", "kept" : { "confetti" : { "v" : 0, "value" : { "velocity" : 240 } } }, "kind" : "ellipse", "props" : { … } }
  ],
  "versions" : { "added" : { "checklist" : 0 }, "kinds" : { "ellipse" : 0, "sticky-note" : 1 } }
}
```

`format` versions the envelope and each record's own members. The app writes the oldest format
that holds the board: 3 if any shape has [added values](#added-properties) (in `added`, or kept in
`kept`), else 2 if any has [metadata](#metadata) (in `meta`), else 1. So an older app opens every
board it would save back whole, and refuses one it would save without what it doesn't know.
Formats 1 and 2 give each kind's version in `schema`; format 3 in `versions`, beside each added
property's (`kinds` and `added`). A shape's `props` are its kind's own properties; the values of
the properties plugins add to its kind are beside them, in `added`, by key. What a shape doesn't
have is left out. The camera, the selection and whether the details and the minimap show aren't
in it: they're remembered per file on this Mac, so panning never marks a board edited.

**Edited, and saved.** A board is edited as a step begins, and counted back as a step comes to
nothing or is undone ([Undo](#undo)): `BoardDocument` makes NSDocument's own change-count calls as
the history's events come, at once, rather than through an undo manager (it has none). So undoing
to what was saved reads unedited, undoing past it edited, and redoing edited again. Every save
closes the step under way, so what was saved is a step boundary, and what's typed after it is a
step the save didn't see, which marks the board edited again: a long typing session may split at
an autosave, as TextEdit's does. A periodic autosave that comes during a press (a drag) gives way
(`CocoaError.userCancelled`, which NSDocument doesn't show) and runs once the press is over;
`BoardDocument.snapshot(implicitlyCancellable:)` is what a save writes.

**A kind versions its own props.** Its migrations sit beside `static let kind`, and their count
is the version boards record. The sticky note's steps handed its checklist over to Checklists, then
its title to Titles:

```swift
public struct StickyNote: BoxShapeProps {
    public static let kind: ShapeKind = "sticky-note"
    /// Append only. The count is the version boards record.
    public static let migrations = [
        // Checklists adds the checklist to every kind that opts in; the note no longer keeps one.
        PropsMigration.handOver("checklist", to: ChecklistProperty.self),
        // So does Titles the title, once someone names the note.
        PropsMigration.handOver("title", to: TitleProperty.self),
    ]
    ...
}
```

A task card took one more step between the two, since it wrote a blank title for an untitled task,
which Titles keeps as none: `PropsMigration("a blank title is none") { props in ... }` drops it
before `handOver("title", ...)` hands the rest over.

A step is one of three:

- **`PropsMigration("…") { props in ... }`** rewrites one shape's props as JSON (`JSONObject`), since
  old props may no longer decode.
- **`PropsMigration("…")`**, with no body, is the step for a new member with a default. Boards
  from before it read as the default, but it still takes a version: otherwise an older app would
  read a board this one wrote as its own version, and drop the member when it saved. The version
  also gets its fixture.
- **`PropsMigration.handOver("checklist", to: ChecklistProperty.self)`** hands one of the kind's own
  members over to an added property the kind now opts into. Reading an older board moves the
  member's value from `props` to `added`, as the property's value at the version the step names
  (`version:`, the property's version when the step is written; it defaults to 0, so pass it if the
  property already has steps. Pinned, it stays right as the property takes steps of its own), then
  migrates it by the property's history. Sticky notes and
  task cards took this step at version 1, when Checklists moved onto `ChecklistProperty`, and again
  when their titles moved onto Titles' `TitleProperty` (a note's version 2, a task's 3).

The rules:

- Any change to how a kind's props encode needs a step: a member renamed, removed or retyped, a
  changed unit or meaning, a new member. A step removes what it retires: a member it leaves behind
  is no longer the kind's, and reading drops it.
- Migrations are append only, pure (only that shape's props: no registry, no other shapes, no
  clock, no randomness) and up only.
- A kind's string never changes once shipped, nor does an added property's key.
- An added property versions its own value, once, whatever kinds opt in: its
  `static let migrations`, a list of `PropertyMigration`s, each rewriting one shape's value as JSON
  (`JSONValue`, since a value may be an array or a string), with the same rules. A value several
  kinds keep belongs in an added property, so it has one history rather than one per kind.
- Each shipped kind has a fixture per version, `Tests/CompositionTests/Fixtures/kinds/<kind>.v<N>.json`,
  one shape's props as boards of that version wrote them. `expectKindFixtures` (CanvasTesting)
  checks that every fixture migrates and reads, with any member its history hands over reading as
  that property, and that today's holds every property the kind lists and writes back byte for byte,
  so a props change without a migration fails, even a new optional member (which a board leaves out
  when nil). Each shipped added property has the same, `Tests/CompositionTests/Fixtures/added/<key>.v<N>.json`,
  one shape's value, held by `expectPropertyFixtures` to the byte-for-byte check alone: a value's
  fixture, and the structs inside a kind's, should set every member, so a new one changes the bytes. Add a fixture for each new version; never
  edit one. The registry's report shows each kind's version once it has one (`shape sticky-note
  v1`), and each property's.

**Opening never drops a shape.** What the app can't use is kept aside (`AnyShapeRecord.isOpaque`),
in its place in the stack, and saved back as it was, with its own version (`v`): a kind no plugin
installs, a newer version of a kind, or props that don't read (or don't migrate, or have a frame
that isn't finite). Nothing draws, hits, selects or edits a kept-aside shape; a horizontal that goes
through every shape skips `isOpaque` records, as Validation does. A kept-aside shape keeps its added
values the same way, in its `kept`.

**Nor a value.** An added value the app can't use (no installed plugin declares the property, the
shape's kind doesn't opt in, it's from a newer version of the property, or it doesn't read or
migrate) is kept in the shape's `kept`, by key, with its version (`{ "v" : 0, "value" : … }`), and
written back as it was. The shape itself is usable, just without it (`record.keptProperties` names
what it keeps), and nothing can set it. Once the app can use it (the plugin installed, the kind
opted in), it's taken back into `added`. Opening also fills in the defaults of what each kind opts
into, which doesn't mark the board edited.

It repairs ids that repeat or are missing, and stacking keys that don't rise, and leaves out
metadata, or added or kept values, that aren't an object by key (a kept one with its version):
those can't be anything's (`droppedMeta`, `droppedValues`), and the report says so.
`LoadedBoard.report` says what was kept aside (`keptAside`, the shapes; `keptValues`, the values on
shapes the app can use) and what was repaired; the window shows it, offering to delete the shapes
kept aside but never to discard a value. Repairs mark the board edited, so saving keeps them. Only
a file that isn't a board, or comes from a newer app, refuses to open (`BoardReadError`).

## The registry

`Registry(plugins:)` runs every plugin's `register(into:)` once, after the core's own plugin (the
hand tool). It then checks everything and throws on:

| Error | When |
|---|---|
| `duplicatePlugin` | The same plugin id twice. |
| `ownerNotInstalled` | A contribution to a point whose owner isn't in the list. |
| `unknownKind` | A contribution for a kind no plugin registers. |
| `conflict` | Two claims to the same key: a kind, a tool id, a service type, a command, the default tool, the secondary click, key strokes, an added property's key (two declarations), one kind's opt-in to a property (from two plugins, or twice from one), or a key in any `KeyedExtensionPoint` (a keyboard shortcut's chord, one kind's double-click claim, one adornment on a kind). |
| `invalid` | A property list that doesn't hold up, two types under one definition name, or a struct that holds itself with no name ([Properties](#a-kinds-own-properties)); an opt-in to a property no installed plugin declares, a plugin opting a kind into one both by itself and through `optInEveryShape`, or a kind opting into a property named like one of its own ([added properties](#added-properties)); or a point's own `check` refused the list (the default tool must be a registered one). |

Some rules span contributions in a way keys can't express. For those, a point implements `check`,
which the registry calls once it's built, after the checks above, so a point may assume its owner
is installed and its keys are unique:

```swift
public protocol ExtensionPoint {
    associatedtype Contribution
    static var owner: PluginID { get }
    /// Rules that span contributions: runs once the registry is built, for each point that has
    /// at least one contribution. Throwing refuses the plugin list.
    static func check(_ registry: Registry) throws      // default: checks nothing
    /// How the registry's report shows a contribution.
    static func summary(of contribution: Contribution, for target: ShapeTarget) -> String   // default: the point, and its kind
}
```

Throw `RegistryError.invalid(point:reason:)`, which reaches the caller as it is, or any other error,
which the registry reports as `invalid` for your point. The requirement is untyped, so `throws` and
`throws(RegistryError)` both implement it. Declare the point's conformance in an extension
(`public enum ShapeDetails {}`, then `extension ShapeDetails: KeyedExtensionPoint { ... }`), so a
misspelled `check` fails the build instead of leaving the default in place. The same goes for
`summary`, which says how [the report](#the-registry) shows a contribution: by default the point's
name and the kind it's for (`ValidationRules → sticky-note`); Keyboard's shows the key and what it
does (`shortcut V → tool select`).

It runs once per point that has contributions, in the order of each point's first contribution,
and may read any point's contributions. `ShapeDetails` uses it to refuse two tab types with one
title, which would show as two identical tabs. Had TaskCards kept a Checklist tab of its own next to
the one Checklists brings:

```
ShapeDetails: Checklists.ChecklistTab (from sticky-notes) and TaskCards.ChecklistTab (from task-cards) are both tabs titled "Checklist"; share one, or retitle one
```

The hook is generic: the core runs it without knowing what any point checks.

Once built, it's frozen and handed to the editor. The app's list is
`ShippedPlugins.plugins(pasteboard:model:)` in [Composition](../Sources/Composition/ShippedPlugins.swift),
and a test checks it registers.
`registry.report` prints who contributes what: the runtime half of the graph, pinned by a test.

```
core                 tool hand · command undo · command redo
keyboard             service KeyboardState · key strokes · shortcut H → tool hand · shortcut ⎋ → Cancel · shortcut ⌘. → Cancel · shortcut ⌘Z → command undo · shortcut ⇧⌘Z → command redo
selection            service SelectionState · tool select · shortcut V → tool select · default tool select · outlines · overlay HandlesOverlay · command delete · shortcut ⌫ → command delete · shortcut ⌦ → command delete · command selectAll · shortcut ⌘A → command selectAll · command goBack · shortcut ⌘[ → command goBack · shortcut ↩ → Edit Selection · shortcut ⌤ → Edit Selection
arrows               shape arrow · ContentsRows → arrow · service ArrowTargeting · tool arrow · shortcut A → tool arrow · overlay BindingHintsOverlay
sticky-notes         shape sticky-note v3 · tool sticky-note · shortcut N → tool sticky-note · DoubleClickPlacement → sticky-note · ValidationRules → sticky-note · property checklist → sticky-note · ShapeChecklists → sticky-note · ShapeDetails → sticky-note · ShapeContextMenus → sticky-note · property title → sticky-note · ShapeTitles → sticky-note · ContentsTitles → sticky-note · ShapeDetails → sticky-note · ContentsRows → sticky-note · ports note-link → sticky-note · mention text → sticky-note · mentionable → sticky-note · channel note-link
ellipses             shape ellipse · tool ellipse · shortcut O → tool ellipse
task-cards           shape task-card v3 · tool task-card · shortcut T → tool task-card · ValidationRules → task-card · ShapeDetails → task-card · ShapeContextMenus → task-card · ContentsRows → task-card · property checklist → task-card · ShapeChecklists → task-card · ShapeDetails → task-card · ShapeContextMenus → task-card · property title → task-card · ShapeTitles → task-card · ContentsTitles → task-card · ports task-link → task-card · mentionable → task-card · channel task-link
schemas              service SchemaSync · shape schema-card · tool schema-card · shortcut S → tool schema-card · ValidationRules → schema-card · ShapeTitles → schema-card · ContentsTitles → schema-card · ContentsRows → schema-card · ShapeDetails → schema-card · ports schema-link → schema-card · channel schema-link
validation           service ValidationEngine · overlay ValidationOverlay · ValidationRules
adornments           service AdornmentState · overlay AdornmentOverlay · CanvasButtons · DecorationHits
detail-panel         service DetailPanelState · ShapeDetails
context-menus        service ContextMenuState · secondary-click menu
table-of-contents    service ContentsState
checklists           property checklist · adornment ChecklistChip → every shape
titles               property title · adornment TitlePill → every shape
mentions             service MentionState · overlay MentionFrames · ShapeFaces
validation-details   DetailStatuses in Issues
validation-contents  ContentsMarks
clipboard            service ClipboardState · command cut · shortcut ⌘X → command cut · command copy · shortcut ⌘C → command copy · command paste · shortcut ⌘V → command paste · CanvasContextMenu
locking              property locked · property locked → every shape · read-only shapes · service LockState · adornment LockChip → every shape · CanvasContextMenu
ports                property channel · service PortState · overlay PortOverlay · CanvasButtons
arrow-ports          property channel → arrow · connector → arrow · ArrowBindingRules
language-models      service LanguageModelState
automation           command line create · command line kinds
rectangles           shape rectangle · tool rectangle · shortcut R → tool rectangle
polylines            shape polyline · tool polyline · shortcut L → tool polyline
eraser               tool eraser · shortcut E → tool eraser
ellipse-titles       ShapeTitles → ellipse · ContentsTitles → ellipse
reordering           ShapeContextMenus
```

A horizontal's opt-in shows as what it contributes: `note.checklist()` is the opt-in to the property
checklists declares (`property checklist → sticky-note`), then a `ShapeChecklists` entry, a
`ShapeDetails` entry and a `ShapeContextMenus` entry, which is why task-cards has two of each of the
last two (its own panel and menu, then the checklist's). `v3` on sticky-note and on task-card
are the versions of their props: each handed its checklist and its title over (a task's title in
two steps: a blank one was an untitled task's, and is dropped first), and a note's text became
mention text ("text may mention shapes", which escapes what would now read as a mention).
`note.title()` is the opt-in to the property titles declares (`property title → sticky-note`), a
`ShapeTitles` entry and a `ContentsTitles` entry (the title naming the row); the `ShapeDetails`
entry after them is the note's header, where it's renamed. Validation's `ValidationRules`, for
every kind, is its schema rule ([Checking shapes](#checking-shapes-against-their-schemas)). Locking opts
every kind in itself (`property locked → every shape`), and `read-only shapes` is its rule for the
core. `ports note-link → sticky-note` is a note's ports and `channel note-link` the channel
StickyNotes declares for them; arrow-ports' `connector → arrow` makes arrows what ports draw, and
brings the opt-in before it (`property channel → arrow`). `mention text → sticky-note` and
`mentionable → sticky-note` are Mentions' opt-ins: a note's text shows pills (`note.mentionText`),
and text may mention a note (`note.mentionable`), as it may a task (`mentionable → task-card`);
`mentions` keeps who mentions whom (`MentionState`), tells the text it keeps drawn
(`MentionTextMemo`) where each frame ends (`MentionFrames`, an overlay that draws nothing), and
makes pills answer clicks (`ShapeFaces`).
Titles places its pill on every shape whose kind's title shows one (`adornment TitlePill → every shape`), Checklists its chip likewise,
and Locking its lock; `adornments` lends them their layout and drawing, a canvas button
(`CanvasButtons`) and their hits (`DecorationHits`), and places none of its own.

## Testing plugins

Tests are plain executables built on a small macro-free kit (swift-testing's macros don't work
with this toolchain, and there's no XCTest). `./test.sh` builds and runs them all.
`TEST_FILTER=substring ./test.sh` runs the matching tests. A test that would open a real menu
(which shows on screen, even from an unshown window) is opt-in: `TEST_UI_MENUS=1 ./test.sh`. There
are two: Checklists' Items menu, and CompositionTests' check that AppKit gives a Control-click to
the context menu before `mouseDown`. [Your first plugin](#your-first-plugin) sets up a test target.
A test that selects and drags as a user does installs Keyboard and Selection first
([ExamplesTests](../Tests/ExamplesTests/ExamplesTests.swift)):

```swift
test("Polylines: the select tool moves a line by its own translation, and Escape puts it back") {
    let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), PolylinesPlugin()])
    let points = [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100)]
    let id = h.add(Polyline(points: points))
    h.press(at: CGPoint(x: 150, y: 101))
    h.drag(to: CGPoint(x: 180, y: 141))
    expectEqual(h.editor.selection, id)
    expectEqual(h.editor.document[id]?.typed(as: Polyline.self)?.props.points, [CGPoint(x: 130, y: 140), CGPoint(x: 230, y: 140)])
    h.escape()
    expectEqual(h.editor.document[id]?.typed(as: Polyline.self)?.props.points, points)
},
```

- `EditorHarness` (CanvasTesting) drives a headless editor like a user: `move`, `press`, `drag`
  (optionally at a speed), `release`, `click`, `hold(modifiers)`, `key`, `escape`, `wait(ms)`. One
  clock drives both event timestamps and the `ManualScheduler`, so pointer speed, timers and the
  hand tool's slide agree. `key("v")` presses a key on the canvas with what `hold` holds
  (`key("\u{1b}")` is Escape, and `isRepeat:` a held key), and says whether a shortcut took it;
  `escape()` runs `editor.cancel()` directly, with or without Keyboard.
- `FixturesPlugin` and `CardsPlugin` (CanvasTesting) give core and horizontal tests shapes to work
  with (`Box`, `Disc`, `Tag`, and the editable `Card`; `CardsPlugin { card, place in ... }` opts
  cards into more, like Selection's double-click), so they never depend on a real vertical. Their
  tools have no keys (CanvasTesting can't import Keyboard): a test picks one with `h.editor.setTool`,
  or registers a key for it (`$0.shortcut("c", forTool: ToolID(placing: Card.kind))`).
  SelectionTests, ArrowsTests, ValidationTests, DetailPanelTests, AdornmentsTests,
  ChecklistsTests, ClipboardTests, TitlesTests, ValidationDetailsTests, ValidationContentsTests,
  LockingTests and PortsTests import no real vertical (only these fixtures, and local test kinds),
  which proves those plugins are shape-agnostic. ArrowPortsTests import one real vertical, Arrows,
  and join fixtures with its arrows.
- **Names of shapes** without a real kind that holds them: `NamingPlugin()` (CanvasTesting) registers
  `Memo`, whose props name shapes in a struct in a list (`MemoNote`), an optional and a dictionary,
  and which opts into `CitationsProperty`, an added set of names; and `CitingTag`, bound to its
  target (`ShapeReferencing`) and naming another. `Citation` is the leaf, and `Citation.visits`
  counts how often any is walked or renamed, so a test can show something never looks at names (a
  delete).
- **Read-only shapes** without Locking: `FreezingPlugin(log:)` (CanvasTesting) declares `Frozen`, a
  flag every kind opts into, makes frozen shapes read-only, and logs the refusals services hear in
  its `RefusalLog`; `editor.freeze(ids)` sets it. CanvasTests, SelectionTests and DetailPanelTests
  hold the core, the selection and the panel to read-only shapes with it, never with a lock.
- CanvasTests run the core with no plugin claiming the default tool, so it's the Hand there, and
  none claiming key strokes, so no key does anything; a test that presses, drags or selects shapes
  the way a user does installs `KeyboardPlugin()` and `SelectionPlugin()` first, as the app does.
- Tests drive the editor's host API, so they `@_spi(Host) import Canvas`.
- `renderBitmap(editor, size:)`, `pixel(_:at:)` and `changedPixels(_:_:in:)` check what's drawn.
- **An editing view against its render.** `renderBitmap(editor, size:scale:editing:)` draws the
  canvas, then an editing view from `editor.makeEditingView()` over the shape being edited, laid out
  as `CanvasView` lays it out (its frame in view points, its bounds in world units), at the bitmap's
  scale, and takes it out of its window again, so the test can type into it and draw it again.
  `lineTops(_:over:in:scale:)` is where each line of text starts: the top of each run of rows that
  differs from the same drawing without the text (the canvas leaves a note's text to its editing
  view), by more than a quarter in a channel. `largestDifference(_:_:in:scale:)` is the most any
  pixel differs in a rect, every pixel counted. StickyNotesTests' `noteEditorTests` hold the
  note's editor to its render with them, at 1× and 2×, zoomed in and out.
- `Contributor(id:) { registrar in ... }` is a plugin written inline, and `editor.add(props)`
  inserts a shape in a transaction of its own.
- **The detail panel.** `editor.detailPanel?.layout(for:)` resolves a shape's header, tabs and
  sections without a view (a tab's status lines are `layout.statuses(in:)`), and `statuses(for:)`
  its footer lines. `editor.shapeBinding(id, as:)`, `editor.frameBinding(id)` and
  `editor.propertyBinding(id, P.self)` are the bindings a section gets: write through them and check
  the document. For the view, host `DetailPanelView` in an `NSHostingView` in an unshown `NSWindow`,
  beside a `CanvasView` when focus matters (DetailPanelTests; CompositionTests' InspectorTests use
  the app's wiring, `CanvasRepresentable` and `ShippedPlugins.detailPanel`). Give the editor the
  real `TaskScheduler`. SwiftUI's updates land on the main run loop, so wait for the state you
  expect with `window.spin { condition }` (CanvasTesting; it fails the test after 2 s), and use
  `window.settle()`, a few turns of the loop, where there's nothing to wait for or the point is
  that nothing more happens. Find controls by AppKit class (`view.descendants(NSTextField.self)`)
  and `stringValue` or `placeholderString`, give a field the keyboard with `window.focus(field)`,
  send keys with `window.type` and `window.press` (`modifiers:` for ⌘A), and press the canvas with
  `canvas.mouseDown(with: window.mouse(...))`: `sendEvent` mouse-downs don't reach views in an
  unshown window.
- **Context menus.** `h.secondaryClick(at:)` (CanvasTesting) right-clicks through the host API and
  returns the `NSMenu`, or nil. `menu.outline` reads it a line per item ("(Brighter)" when dimmed,
  "✓ 1", "– 2" when mixed, "Level ▸" and its items indented, "—" between groups), and
  `menu.choose("Level", "2")` runs an item as a click would, failing the test if it's dimmed. No
  menu goes on screen. `h.hold(.control)` first makes it a Control-click. ContextMenusTests import no
  real vertical.
- **Adornments.** `AdornmentLayout.frames(of:width:)` is pure, so AdornmentsTests hold the layout
  to its numbers and to its guarantees (a seeded property check, over widths from 0 to 400 and
  random adornments). Headless, `editor.adornmentFrames(of:)` is where a shape's adornments are, in
  world units; `renderBitmap` and `changedPixels` check what's drawn (a pill that stops 4 points
  short of a lock changes no pixel beside it); and `editor.hoveredButton` on a clickable one is
  `AdornmentButton(A.self, on: id)`. A test's own adornment types are internal, not private, so a
  conflict key names one as `Module.Name`. A plugin list with Titles, Checklists or Locking needs
  `KeyboardPlugin()`, `SelectionPlugin()` and `AdornmentsPlugin()`, which goes before the plugins
  that place adornments, as the shipped list has it. In debug builds, `editor.adornmentsKept`
  counts the shapes whose labels are kept, so a test holds a deleted shape to being forgotten.
- **The clipboard.** A test that copies gives the clipboard a pasteboard of its own, so it never
  touches the user's: `ClipboardPlugin(pasteboard: NSPasteboard.withUniqueName())`, or
  `ShippedPlugins.makeEditor(pasteboard:model:)` (and `releaseGlobally()` it after). Two editors on one
  pasteboard are two boards copying and pasting between them.
- **The language model.** No test reaches the network: every shipped list a test builds gets a
  `ScriptedLanguageModel` (`ShippedPlugins.makeEditor(model:)`, whose `model:` has no default so
  none can be forgotten), which keeps each request, answers from its queue, and holds its answers
  while `holdsAnswers` until `release()`. A call lands on the main actor, so a test turns the main
  run loop until it has (TestKit's `spinRunLoop(until:)`, `awaitResult { … }`). LanguageModelsTests
  stub the network itself with a `URLProtocol`.
- **Ports.** PortsTests hold the horizontal without an arrow: `portsHarness` installs Keyboard,
  Selection, the fixtures, Ports, `channelsPlugin` (boxes have ports on its `Wire` channel, with the
  `sides:` and `role:` a test asks for, and discs on `Pipe`) and a connector over CanvasTesting's
  `Tag` that only records (`connectorPlugin(Connections())`: `begun` lists each `Connection`, its
  session appends each drag to `drags`, and `canConnect` and `draws` make it refuse). A 200 × 100
  box at (100, 100), `boxFrame`, has its dots at `topDot`, `rightDot`, `bottomDot` and `leftDot`, at
  zoom 1. A test moves onto a dot before pressing, as a user does (`h.hoverDot` comes from the
  shape's middle): dots draw only while `editor.pointerOverCanvas` is set. ArrowPortsTests draw real
  arrows on a `PortBoard`: boxes A and B where the POC's first two welcome notes are, taking
  `Wire`, and a disc C below B taking `Pipe`; `board.connect(to:speed:release:)` hovers A and drags
  from its right dot (`aRightDot`), `fast` or `slow`, and `board.arrows` are the arrows drawn, with
  their bindings and `ChannelProperty`.
- **The command line.** A test listens on a socket of its own (`temporarySocketPath()`, TestKit),
  never the app's. The app answers on the main actor, so a test that's also the client makes its
  request off the main thread while the main run loop turns (`offMain`), or runs `canvas` as it's
  built (`run(builtExecutable("CanvasCLI"), arguments)`, which turns the loop until it's done).
  CanvasRPCTests hold the wire to its messages, arguments and sockets; CanvasCLITests run `canvas`
  against an app of their own (a listener with a few commands) for its output, errors and exit
  statuses; AutomationTests run the commands on a headless editor, spelled as `canvas` spells them
  (`spec.params(from:)`); and CompositionTests' CommandLineTests run `canvas` against the app's
  `CommandServer` on boards configured as the app configures them.
- **What AppKit logs.** Some of AppKit's complaints go only to standard error (NSLog), and the test
  passes anyway. `standardError(during:)` (CanvasTesting) returns what was written there while a
  closure ran, and writes it on after, so a test can check: TableOfContentsTests and CompositionTests'
  ContentsPanelTests check that changing what the table of contents lists logs no
  `tableReentrancyWarning`.
- **What a change redraws.** SwiftUI asks a view for its body again whenever something it read
  changes, so a view that reads more than it shows redraws when it hasn't changed, and rows that all
  read one value all redraw when it changes. Headless, `withObservationTracking { … } onChange:
  { … }` shows what a read observes (a row's tint, `contents.isHovered(id)`, hears only its own
  shape's hover). In a window, the table of contents counts, in debug builds, how often the list has
  asked a row for its view (`contents.rowsRedrawn`), so HoverTests holds a hover over a list of
  150 rows (a list of 200 or more logs `tableReentrancyWarning` as it first shows) to the one or
  two rows it changes. AffectedRowTests holds a drag of a shape other rows read to redrawing its
  own row alone, and a rename of it to redrawing theirs too.
- A test target is `Tests/<Name>Tests` with a `main.swift` that calls `runTests([...])`. Every
  `Suite` must be listed there (`test.sh` checks). `<M>Tests` may depend only on M, what M
  depends on, and the test-support and ui modules.
- **Boards.** `expectKindFixtures(kinds, in: registry, directory:)` (CanvasTesting) holds kinds to
  their fixtures, and `expectPropertyFixtures(keys, in: registry, directory:)` added properties to
  theirs ([Boards on disk](#boards-on-disk)); CompositionTests runs them for every shipped kind
  (`registry.kinds`, in `Fixtures/kinds`) and property (`registry.declaredProperties`, in
  `Fixtures/added`). A document built by hand has none of the defaults an editor fills in, so it
  equals one an editor holds, or one a board reads back as, only after
  `registry.fillingDefaults(document)`. CanvasTests read broken and scrambled boards (a seeded fuzz test), and CompositionTests'
  BoardDocumentTests open, save, revert and host boards with `BoardDocument.configuration` set as
  the app sets it. `./build.sh bench` builds BenchmarkTests in release and holds saving, opening
  (Mentions' index and catalog, built as a board opens, among it), a hover and a drag frame
  (titles' pills, checklists' tallies, locks and mentions' pills in view), a hover on a note's
  port dot and a drag from it, a hover onto a title's pill and onto a mention's, reading the table
  of contents' rows after a drag event, an insert, a delete and a restack, a keystroke in the `@`
  picker (the `@` that opens it too), a rename of a task mentioned 100 times against one mentioned
  by none, the minimap's first picture (a frame at a time) and a drag frame with it, and undoing
  and redoing a drag (with its frame), a tenth of the board's move and deletion and every shape's
  deletion (the steps alone), to their budgets on generated boards of 1,000 and 10,000 shapes
  (three notes in ten mention a task and a shape that isn't there), and reports the first frame
  and the next zoomed out to fit the board (at 10,000, as far as the 10% zoom goes); `./test.sh`
  runs it small, in debug, and only reports.
- **Undo.** `h.editor.undo()` and `redo()` headlessly, with `undoHistory.undoName` for the step's
  name, and `h.editor.undoHistory.seal()` where a user would click or type elsewhere between panel
  writes. A step's round trip is best checked with `==` on the document, and, for a board, its
  `BoardCodec` bytes. `BoardDocument` counts changes as the steps come, so `isDocumentEdited` needs
  no turn of the run loop. For Edit › Undo, use a `BoardWindow` (CanvasUI), `window.editor` set:
  `validateMenuItem` gives the item's title and whether it's enabled, and `window.undo(nil)` runs it
  wherever the keyboard is (CanvasUITests' BoardWindowTests, CompositionTests' UndoTests).
- **The minimap.** CanvasUITests put a `CanvasView` with `showsMinimap` in an unshown window, drive
  `canvas.minimap` with mouse events, and hold its picture, kept through every kind of edit, to a
  new `MinimapView`'s, every pixel. A test that needs a board drawn in one frame lengthens the
  minimap's `frameBudget`, and one that watches it fill in shortens it to a tile a frame.
- **The pointer over hosted views.** CanvasUITests' Pointer suite sends a `CanvasView` holding an
  editing view (CanvasTesting's card) synthesized moves and releases, and reads what a probe tool
  heard (`PointerLog`: moved, exited); CompositionTests' canvas view tests hold the shipped select
  tool to it, `editor.hovered` nil over a note being edited.
- **Faces with editing and going to shapes.** CompositionTests' canvas view tests put a pill-like
  face in the shipped notes (`pillsPlugin`, a 60 × 20 face naming one shape) and hold the pieces
  Mentions uses to working together through `CanvasView`: the pointer over the pill hovers what
  it names, a click edits the note from the pill (`editingStartPoint`) and leaves nothing hovered
  under its text, and on a locked note a double-click goes to what it names, which Back undoes.
  The locked note doesn't shake through the click or the double-click. SelectionTests' Going to
  shapes clicks a link-like face and presses again with a click count of 2 while the camera glides:
  nothing is placed, and the camera arrives.
- **Mentions.** MentionsTests use fixtures only (`MentionFixturesPlugin`: `Jot`, a box of mention
  text with a `MentionTextView` editor, and `Plate`, `Token`, `Endpoint` and `Brief`, with the
  `Blockers` scope; `mentionHarness` puts Keyboard and Selection first). They fuzz the stored
  grammar, hold scopes and their registry checks, names, `MentionState`'s index, observations and
  rows (`textsRead` counts the texts a commit reads, in debug builds), the matcher's tiers, and the
  pill's images; drawing, pixel for pixel against string drawing, and each pill's pixels within
  its `mentionPills` frame (`MentionDrawingCounts`, in debug builds, counts what's built); faces,
  through `EditorHarness`; the text view in an unshown window (`EditedJot`: typing, the picker's
  keys, clicks, the menu, tooltips, copy and paste on `NSPasteboard.withUniqueName()`, undo in a
  plain window, which the view writes back itself, once, and leaving the window with only its own
  steps); the state, the pills and the rows as steps are undone and redone (`editor.undo()`,
  `redo()`: never a record inserted again in undo's place); and the picker's model, headless. AppKit closes an undo group at the end of a turn of the run loop,
  so a test that undoes steps one at a time settles the window (`window.settle()`) between them.
  StickyNotesTests hold a note's text (its third migration, its row, what it's called) and its
  editor to its render with pills (`noteEditorTests`: each pill's frame in the editor, TextKit 2's
  for its attachment, is the canvas's; at a whole number of pixels to a point, the lines start
  alike and the pills' pixels are within a quarter; at 60%, string drawing draws a pill part way
  into a pixel and TextKit 2 on the nearest, so there only the pixels off the pills are held).
  CompositionTests' `mentionsShippedTests` hold the shipped pieces together in a `CanvasView`: a
  task picked with `@`, renamed (the editor, the row and the canvas), deleted and undone; the
  pill clicked on the canvas and double-clicked in the text; a locked note's pill; copying and
  pasting a pill; and the text view's undo written back to the note. In a board's window
  (`UndoBoard`, whose `BoardWindow` gives Edit › Undo to the text with the keyboard), they hold a
  session begun from a pill, with a pick, Remove Mention, a paste and typing, to one step, and a
  note placed and typed into with a pick to one step with its placing, "Add Note"; a pick
  undone in the text to its query, each undo to one write; Undo with the picker open, the text's
  and the board's, to closing it; a deletion and a rename undone to pills as they were; and going
  to a mention to no step, with Back beside Undo. CommandLineTests `create`
  notes that mention shapes, on the board or not.
- **Arrow behavior is pinned to the proof of concept.** CompositionTests replays 30 arrow
  scenarios through `CanvasView` with real events and compares where every arrow ends up, byte for
  byte, with a transcript recorded from the POC. It also compares nine renders pixel for pixel:
  the welcome board, hover and target outlines, binding hints mid-drag, handles and their halos,
  zoomed out. The same replay code (`Tests/CompositionTests/Replay.swift`) drives the POC when
  recording and the app when testing. The recordings come only from the POC:
  `scripts/record-poc-fixtures.sh` rebuilds them from commit 804db97, and re-running it should
  change nothing. Never regenerate them from the app to make a change pass. Scenarios are only
  ever appended, and recorded from the POC. Where the app differs on purpose, the replay says so:
  the "pan" scenario presses H and holds still 100 ms before the release (both do nothing in the
  POC, whose select tool panned), and the welcome renders use the POC's note text
  (`pocWelcomeTexts`), since the shipped board's third note describes the hand tool and the marquee.
  Where a scenario ends differently on purpose, `intendedDeviations` in TranscriptTests replaces
  the golden's line with the app's, and says why; the fixture stays as recorded. There's one: the
  POC brought a pressed shape to the front and the app doesn't, so "move shape" lists its two notes
  in the other order.

## Coming from data-canvas

| data-canvas | Here |
|---|---|
| `definePlugin({ id, shapes, tools, ... })` | `struct XPlugin: CanvasPlugin { var id; func register(into:) }`. A value; functions can generate plugins. |
| `defineShape({ type, util, tools, toolbarItems, validate })` | `registrar.shape(XDefinition()) { x in x.tool(...); x.validate { ... } }`. The kind comes from the props type and is stamped on everything inside. |
| `ShapeUtil` | `ShapeDefinition`: stateless, typed props, defaults from geometry. |
| Static capabilities on the util (`layoutHostCapability`) | Capability protocols found by `as?` (`Editable`, `HandleProviding`, ...). |
| Slot key + `plugin-slot.ts` + `installArraySlot` | An `ExtensionPoint` type declared by the plugin that owns the concern. No strings, no replay. |
| `validate:` on `defineShape` | Sugar on `ShapeRegistrar` published by the horizontal's own module (`note.validate { }`); the core has no such field. |
| `"*"` validators, a validator for another plugin's type | `ShapeTarget.any`; `registrar.validate(OtherKind.self) { }` from any plugin. |
| Keyed / list registries, last write wins | `KeyedExtensionPoint` / `ExtensionPoint`; every collision is an error. |
| `ValidationIndicatorLayer` | `ValidationOverlay`, through the core's overlay point. |
| `toc: { component, filter, getParentShapeId }` on `defineShape`, `TocRegistry` | `x.contentsRow(when:nestedUnder:) { ContentsLabel(...) }`, sugar from the TableOfContents horizontal ([the table of contents](#the-table-of-contents)). |
| `DetailsPanel`'s `emptyView` and `multiSelectView` (the TOC, whole or filtered to the selection) | `DetailPanelView`'s overview, which Composition fills with `TableOfContentsView`. |
| `adornments:` on `definePlugin` (`AdornmentShapeUtil`, the `adornment-attachment` binding with its anchor, offset, gap and slot; `singletonPerHost`, `isEligibleHost`; `attachAdornment` and `toggleAdornment`) | An `Adornment` type (its place and its order band) and a label made from the shape's data, placed with `x.adornment`, `registrar.adornment(_:on:)` or `registrar.adornmentForEveryShape(_:where:)`, whose `where` can read another plugin's point (as the sticker read its referenceable registry). Never a record: nothing to attach, sync, cascade on delete, copy or migrate; one per type per shape by construction; laid out by [Adornments](#adornments), so none overlap. A fact one shows (locked, public) is an [added property](#something-the-user-turns-on) of the shape. |
| `ToolIdle` / `ToolPointing` click-to-create | `Placement` (follow the pointer, or edit), used by place tools and the double-click claim. |
| `toolbarItems` with a decorative `kbd` | A key registered with the Keyboard horizontal (`shortcut:`), collision-checked, that the canvas answers and the tooltip names. |
| `defineChannel({ id, color, ... })`, `registerHostChannel(type, channel)` | A `Channel` type (`id`, `color`) declared by the plugin that owns its meaning, `registrar.channel(C.self)`, and `x.ports(C.self, sides:role:)` on each kind that takes it (`role:` is a port's `end`), collision-checked; an arrow keeps its channel as an added property, `ChannelProperty` ([Ports](#ports)). |
| `EdgeMidpointDots`, the port drag, and `canBind` refusing what a channel doesn't take | Ports' dots, Selection's canvas buttons, whose drag goes to the one connector (ArrowPorts: `editor.beginArrow`), and `registrar.arrowBindingRule`, Arrows' canBind, for arrows already drawn. Released on nothing, nothing is drawn. |
| `install*Lifecycle(editor)` side effects | `registrar.willDelete` inside transactions; `EditorService` for per-editor state. |
| `module.json` + ESLint DAG + barrel `index.ts` | `Package.swift` with layers + `build.sh audit` + the compiler; `public` is the barrel. |
| `plugins.config.ts` | `ShippedPlugins.plugins(pasteboard:model:)` in Composition. |

## Not built yet

Each of these adds to the design without changing what plugins are written against.

- **More of change sets:** each commit already says what it added, changed and removed
  (`ChangeSet`, which services get with `documentDidChange`), and undo keeps the records before and
  after (`DocumentDelta`); what's left is who made it (the user, an agent through the command line).
  Sync builds on them.
- **More of the command line**: reading a board (its shapes, in a form for agents), and changing
  and deleting shapes; who each change is from (an agent's name on its commits, and its cursor on
  the canvas); commands contributed by the plugins that own a concern (a title, a checklist, a
  lock); opening a board that isn't open; putting `canvas` on the PATH from the app (as editors
  install theirs); and other clients of the same socket (an MCP server, say, from the same
  command descriptions).
- **An arrow end bound to a shape that isn't there** (deleted outside a transaction, or kept aside)
  is drawn at the origin; a binding should keep a point to fall back on.
- **More of undo**: showing a change that's out of view as it's undone (the camera never moves
  today); a limit to how many steps a board keeps (there's none); NSDocument's rollback of an
  autosave it can't finish, given up with the undo manager; text's undo falling through to the
  board's once the text has nothing left to undo (it's forgotten when the text loses the keyboard);
  a step per board once a file holds several; agents' changes as steps of their own, with who
  made them; and a change that lands on its own during a press (a model's answer the schema card's
  sync writes) kept out of the press's step, which it joins today.
- **More document hooks** (before/after create and change), and **document-scoped services** for
  several windows on one board.
- **More of schema cards**: keeping the last sync in the card's metadata, so any card saved out of
  step (a failed sync, a call cut off by closing) opens knowing it, not only one whose schema has
  no fields; a patch in place of the whole schema, so a big schema can be edited from its
  description (and a long one answered sooner); streaming, for answers longer than a request that
  doesn't stream should wait for; and schemas that type or check other shapes.
- **An editing view hearing about outside changes** to its shape (undo ends editing first, but an
  agent's or another window's change won't).
- **Canvas features**: resize and rotate handles on the selection box; snapping; ⇧ locking a move
  to an axis; ⌥-drag to clone; the scribble brush; arrow-key nudging; a long press starting a drag;
  the "move" cursor while moving shapes; and hierarchical tool states once the select tool has more
  than a handful of sessions.
- **More panning**: the space bar, and middle- or right-button drags, through a host entry point of
  their own (not `setTool`, which resets arrow targeting); the canvas scrolling at its edges while
  brushing or moving, hit-testing again as the camera moves (a scroll mid-brush waits for the next
  drag event today); the hand tool's double-, triple- and quadruple-click zoom; and a slide timed by
  the display rather than nominal 16 ms frames.
- **More horizontals** from data-canvas: describe, search, commands. Each is an extension point in
  its own plugin.
- **More of titles**: a double-click on a pill renaming it (an adornment's own double-click: a
  double-click there is its shape's today, which edits a note); a Rename item in the context menu;
  and titles on kinds without a frame, such as arrows (tldraw's labels, along the arrow) and lines.
- **More of adornments**: more places (the other corners and edges, below a shape, and along a
  shape without a frame, as an arrow's label); an adornment's own double-click and menu items;
  labels read from other shapes (with an `affected:`, as the table of contents' marks have);
  adornments that draw themselves (data-canvas's 22-point sparkline, which needs a taller row);
  adornments painted with their shape, so a shape in front covers a back shape's, and a press
  there is the front shape's (a per-shape drawing hook in the core); a tooltip on each (the lock's
  among them); telling agents what a shape shows; and, zoomed far out over a big board, leaving
  out text too small to read (the first frame there makes every adorned shape's labels).
- **More of going back**: going forward again (⌘]), and a step keeping what the table of contents
  listed, so Show All survives a trip back.
- **More of the keyboard**: a window listing every shortcut; menu items that take their key
  equivalents from Keyboard, so the View menu's zoom keys and Edit › Select All's ⌘A are declared
  once; and keys the user remaps.
- **More of the table of contents**: nested shapes (a shape's container as the default
  `nestedUnder`), with each row's disclosure remembered (every nested row starts collapsed today);
  dragging rows to restack their shapes; per-kind zoom targets
  and click actions (data-canvas's `getZoomConfig` and `onClick`); Return editing the selected
  shape; arrow rows that name the shapes they join; and rows all of one height, which AppKit
  never measures from inside a measurement, so it would stop logging its reentrancy warning
  ([What's listed](#whats-listed-and-selecting)): a list of our own, since a SwiftUI `List`'s rows
  size themselves.
- **More of validation**: listing just the shapes with issues in the table of contents (a filter
  beside Show All), and going to the next one from anywhere (Xcode's ⌘'), for a board too big to
  look down for dots; an issue in the Issues tab going to the row it's about, which the panel would
  mark (below); and rules that depend on the clock (a task overdue), which the engine, caching by
  revision, can't keep up to date today.
- **More of the clipboard**: pasting what other apps put on the pasteboard (text as a note, an
  image) and giving them a text or image version of copied shapes; pasting at the pointer
  (tldraw's preference, and ⌥); and Duplicate (⌘D) and ⌥-dragging a copy, on the same copying.
- **More of the context menu**: more items for the canvas (Select All, on empty canvas); key
  equivalents and symbols on items; and the items everyone expects, such as Delete
  and Duplicate, once a plugin owns them.
- **More of locking**: Unlock All (tldraw has it); a lock on a shape's row in the table of
  contents; the menu's other items for a locked shape dimmed, rather than shaking it once chosen;
  a line in the detail panel saying why it's disabled; and a tooltip on the chip (an adornment's,
  above).
- **More of ports**, most of which data-canvas has: a channel's cardinality (at most one
  connection at an end, and a dot that stops taking more); wildcard channels (a port on every
  channel); directional reversal (a drag from a port that only takes connections, drawn the other
  way round); ports on part of a shape (a row, a checklist item); an arrow's start pinned to its
  dot's side, and its end to the side of its shape facing it (data-canvas's `anchorToPort`; a
  precise start at a side's midpoint means nothing without it, since tldraw's clipping starts an
  arrow where it crosses its shape's edge toward the other end, whichever side that is); a
  channel's title, and a legend of the channels; a line in an arrow's detail panel naming its
  channel; reading connections as data (what a note links to, for rules and agents); and, once
  ports draw every arrow a board needs, removing the arrow tool (the POC's transcript drives it
  today).
- **More of properties**: a board's shapes checked against their schemas as it opens, in its report
  (the command line's `create` warns about what it makes, and `canvas kinds --schema` hands the
  schemas out); a projection of
  a schema for LLM tool calling, whose strict modes reject `prefixItems` and `oneOf` (a rect, a
  task's status); panel controls made from a schema, a title's field counting down to its
  `maxLength`; bounds a kind sets on an added property (Titles' 80 characters are every kind's);
  sections and menu items that turn on a property whose default is nil (they show only once it's
  set today); and discarding a kept value.
- **More of checking shapes against their schemas**: `unevaluatedProperties`, `dependentSchemas`
  and references to other documents, which no schema here writes; and checking only the parts of a
  shape its schema bounds, for the first read of a large board (10,000 shapes take about 30 ms).
- **More of mentions**: mention text in the detail panel (a field for a task card's notes, a
  panel text view shared with schema cards), in task cards' notes and checklist items, and on the
  canvas where they're drawn; a text restricted to some kinds among the shipped ones (what may
  block a task); a shape's backlinks ("Mentioned in"); validation of mentions that are missing or
  outside their scope; mentions of shapes on other boards; the command line reading and listing
  what can be mentioned; more kinds mentionable (through bridges); and making a shape from the
  picker.
- **More of the detail panel**: editing several selected shapes at once (it shows "N Shapes"
  today); every-shape sections over the record (there are every-box ones over the frame, and those
  over an added property), and every-box overrides such as an aspect lock;
  remembering the chosen tab and collapsed sections across launches (`DetailTabID.name` is stable
  for that); and marking the row a validation issue is about (`ValidationIssue.field`).
