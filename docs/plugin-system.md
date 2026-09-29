# The plugin system

Everything on the canvas comes from a plugin: sticky notes, arrows, schema cards, subboards,
validation, titles, the pills and chips shown on shapes (adornments), the detail panel
and the table of contents beside the canvas, selecting itself, copying and pasting, locking, the
ports arrows are dragged from, text's mentions of shapes, the graph of what connects to what, the queries that find shapes in a file, snapping what's dragged to the shapes around it, what each key does, what the command line can do, the language model plugins ask, even the examples.
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
- [Topology](#topology)
- [Queries](#queries)
- [Boards](#boards)
- [The command line](#the-command-line)
- [Schema cards](#schema-cards)
- [Language models](#language-models)
- [Snapping](#snapping)
- [Capabilities](#capabilities)
- [The editor, the document, and drawing](#the-editor-the-document-and-drawing)
- [Skeletons](#skeletons)
- [Boards in a file](#boards-in-a-file)
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

extension RectangleDefinition: CustomSkeleton {
    func renderSkeleton(_ shape: ShapeRecord<Rectangle>, in context: RenderContext) {
        context.cg.setFillColor(NSColor.systemTeal.cgColor)
        context.cg.fill(shape.frame)
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
its default. `RectangleDefinition` says how it looks, in full and zoomed out, where the canvas draws
every shape more simply (`CustomSkeleton`: its teal in one fill, without the shadow, where it would
otherwise be the core's gray: [Skeletons](#skeletons)), and a kind with a frame needs to say nothing
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
build.sh: Rectangles (vertical) may not depend on StickyNotes (vertical); vertical may use: foundation horizontal
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
| Hit or outline a shape more exactly than its frame | Override `geometry`, `hitTest` or `indicatorPath` | [Polylines](#a-shape-without-a-frame), [StickyNotes](../Sources/StickyNotes/StickyNotes.swift)' rounded outline |
| Draw a kind more simply zoomed out, where its text doesn't read, and cheaply, since thousands are in view | `CustomSkeleton`'s `renderSkeleton`: fills, `context.fillSkeletonText` for bars where its text is (as long as its columns, `SkeletonText.columns(of:)`), or `context.drawSkeleton(of:color:)`, the default, in a color of its own; `CustomSkeletonOutline` for an outline there that isn't its kept geometry's | [Skeletons](#skeletons), [Rectangles](#your-first-plugin) |
| Make what an overlay draws, or what answers the pointer, follow what a shape shows zoomed out | `editor.drawsSkeleton(of:)` and `OverlayContext.drawsSkeleton(of:)` (each shape's level: the one being edited is in full), `OverlayContext.drawsSkeletons` (the frame's), and `EditorService.drawsSkeletonsDidChange` for a pointer held still | [Skeletons](#skeletons), [Adornments](#drawing-and-cost) |
| Edit a shape in place, as text | `Editable`, and an `editingPlacement` | [StickyNotes](../Sources/StickyNotes/StickyNotes.swift) |
| Add a tool that makes no shape | `registrar.tool`, a `Tool` and a `Session` | [Eraser](#tools-and-sessions) |
| Give a tool its key | `shortcut:` on the call that registers the tool (Keyboard's) | [Rectangles](#your-first-plugin) |
| Make a key do something, or give a menu's command its key | `registrar.shortcut(chord, "Title") { ... }`, `registrar.command(_:shortcuts:)` | [Keyboard shortcuts](#keyboard-shortcuts) |
| Give a shape handles to drag | Selection's `HandleProviding` | [Arrows](../Sources/Arrows/ArrowDefinition.swift) |
| Edit a kind's properties beside the canvas | `x.details { DetailSection(...) }` | [Schemas](#the-full-showcase-schema-cards) |
| Add items to a kind's right-click menu | `x.contextMenu { MenuItem(...) }` | [Boards](#contributing) |
| Add a right-click item to every shape, or every kind with a capability | `registrar.contextMenuForEveryShape(where:)` | [Reordering](#every-shape-reordering) |
| Say how a kind's shapes appear in the table of contents | `x.contentsRow { ContentsLabel(...) }` | [StickyNotes](#the-table-of-contents) |
| Show in a kind's row what other shapes say (the names of the shapes it mentions), kept up to date | `x.contentsRow(affected: { changes, context in ... }) { shape, context in ContentsLabel(...) }` | [Rows read from more than their shape](#rows-read-from-more-than-their-shape) |
| Give a kind a title: a `title` in its schema, a pill on the canvas, and its row's name | `x.title()`, which Titles keeps (1 to 80 characters); or `x.title { ... }`, derived; or both, derived for the shapes nobody named | [Titles](#a-horizontal-plugin), [Schemas](#schema-cards) (derived) |
| Rename a shape in the detail panel's header | `x.details(header: { $x in TitleHeader($x) }) {}` | [StickyNotes](#renaming-in-the-header-titleheader) |
| Name a kind's rows in the table of contents from another plugin | `x.contentsTitle { ... }` | [Titles](#a-horizontal-plugin) |
| Add a concern any kind can opt into | An `ExtensionPoint`, sugar on `ShapeRegistrar`, and whatever reads the point | [Titles](#a-horizontal-plugin), [Validation](../Sources/Validation/Validation.swift) |
| Warn about something on a shape, without running again on every drag event | A validation rule, `x.validate(ignoringMoves: true) { … }` (or `validateEveryShape`), for one that reads what shapes are, never where | [Validation](#a-horizontal-plugin), [MentionValidation](#warnings-mentionvalidation) |
| Give the shapes of the kinds that opt in something to hold (a title) | A `ShapeProperty`, `registrar.declare`, and `optIn(to:)` from the concern's sugar | [Titles](#added-properties) |
| Give that concern a tab on the kinds that opt in | A `DetailTab` at order 50, contributed from the same sugar | [Boards](#a-horizontals-feature-tab-boards) |
| Give that concern menu items on the kinds that opt in | A `MenuGroup` at order 50, and `contextMenu` from the same sugar | [Boards](#a-feature-that-comes-with-menu-items-boards) |
| Edit an added property in the panel, or from the menu | `details(of: P.self) { DetailSection ... }`, `contextMenu(of: P.self) { MenuItem ... }` | [Added properties](#added-properties), [a flag](#something-the-user-turns-on) |
| Show a section in the panel only while a service says so (what mentions the shape) | `DetailSection(…).shownWhile { shape, context in … }`, at order 300 for a tab that comes and goes | [Contributing](#contributing-two-points-and-their-sugar), [Mentions](#what-mentions-a-shape) |
| Edit text that isn't a string in the panel, with a text view of your own | A `DetailTextView` subclass adopting `DetailTextContent`, in a `DetailTextBox` | [Text of a plugin's own](#text-of-a-plugins-own-detailtextbox) |
| Opt another plugin's kind into a concern | A bridge, which imports both; `registrar.optIn(Kind.self, to:)` for an added property | [RectangleTitles](#a-horizontal-plugin), [ValidationDetails](#a-tab-of-status-lines-from-a-bridge-validationdetails) |
| Keep state per editor: an engine, a cache, a timer | `registrar.service`, an `EditorService`; redo what's kept per shape for the shapes each commit's `ChangeSet` names | [Validation](../Sources/Validation/Validation.swift)'s `ValidationEngine`, [TableOfContents](../Sources/TableOfContents/ContentsState.swift)' `ContentsState` |
| Show something small on shapes, just outside them or on a corner (a pill, a tally, a lock), on kinds you define or not | An `Adornment` type; `x.adornment`, `registrar.adornment(_:on:)` or `registrar.adornmentForEveryShape(_:where:)`, returning an `AdornmentLabel` | [Adornments](#adornments), [Titles](#a-horizontal-plugin) |
| Let the user put a flag on a shape, and show it | An added property, a menu item that sets it, and an adornment whose label reads it | [Something the user turns on](#something-the-user-turns-on) |
| Keep a service's state for going back to a board | `EditorService.boardWillChange` and `boardDidChange`, with a `BoardStash` (else a switch is heard as a commit of every shape) | [Showing a board](#showing-a-board) |
| Write to a shape on a board that isn't shown (an answer that lands late), as an undo step made there | `editor.transact(on: board, "Name") { … }`; services hear it in `ChangeSet.boardsChanged` and `elsewhere` | [Boards that aren't shown](#boards-that-arent-shown) |
| Draw above every shape something that isn't one shape's adornment (a status outline, hints) | `registrar.overlay`, a `CanvasOverlay`; `editor.paintOrder(in: context.visibleRect)` | [Validation](../Sources/Validation/Validation.swift), [Arrows](../Sources/Arrows/ArrowDefinition.swift)' binding hints |
| Act on shapes about to be deleted (delete what depends on them) | `registrar.willDelete` | [The document](#the-editor-the-document-and-drawing) |
| Create a kind with a double-click on empty canvas | `x.createOnDoubleClick(place)` | [StickyNotes](../Sources/StickyNotes/StickyNotes.swift) |
| Give each shape of a kind a board of its own, saved, deleted and copied with it | `BoardOwning` on its definition, nothing to implement; `editor.showBoard(BoardID(owner:))` shows one | [Boards in a file](#boards-in-a-file) |
| Make a double-click, Return or ⌘↓ on a kind's shape do something other than edit it (show its board) | `x.opens("Open") { shape, editor in ... }` (Selection's `ShapeOpening`) | [Selection](#selection) |
| Make a kind's shapes open onto the boards they own: Open in its menu and panel, ⌘↑ back up, and a name on the path | `x.opensBoard(placeholder:systemImage:)` (Boards), on a `BoardOwning` kind | [Boards](#boards) |
| Show where you are in a file's boards, and go up | `BoardPath(editor:rootName:)`, over the canvas; `editor.goUp(to:)`, `editor.name(of:root:)` | [Boards](#boards) |
| Put a board inside the board | `SubboardsPlugin`: the Subboard tool (B) places a card that opens onto a board of its own | [Subboards](#subboards) |
| Show on a shape what the board it owns holds | `context.drawBoardPreview(ofBoardOwnedBy:in:)` in its render: a rough picture, false until it's built | [Board previews](#the-cores-part-board-previews) |
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
| Connect two shapes without a drag, as a connector would from a port | `make` and `ends` on `registrar.connects`; `registry.connection(_:existing:in:)`, `registry.connectionEnds(of:)` | [Connecting without a drag](#connecting-without-a-drag) |
| Let agents (or scripts) do something to a board from outside the app | `registrar.automationCommand("name", "…", params: P.self) { params, context in … }`: a `canvas` command | [The command line](#the-command-line) |
| Have a command answer later (it waits on a model, or runs off the main actor), its output written off the main actor | `registrar.automationCommand(…, runAsync: { params, context async throws(AutomationError) in … })` | [A command may be async](#a-command-may-be-async) |
| Read text as a kind's property reads it (a value typed by its schema), or say briefly what a property takes | The core's `KindSchema(schema)`, over `registry.schema(for:)` | [A kind's schema](#a-kinds-schema) |
| Let `canvas draw` name shapes, draw edges, or warn about what it draws, from the plugin that owns the concern | A bridge: `registrar.drawNames`, `drawEdges` or `drawChecks` | [TitleNames, PortEdges, ValidationChecks](#what-draw-takes-from-other-plugins) |
| Make or change a shape without the pointer: what a kind's tool places, a shape from its JSON, or some of a shape's properties set from JSON | `registry.placement(for:)`, `placement.shape(at:)`; `registry.shape(_:properties:)`, `registry.shape(_:setting:)` | [The command line](#making-and-changing-shapes-without-the-pointer) |
| Draw a shape away from where it is, for an animation (a shake) | `editor.setDrawingOffset(_:for:)`; adornments follow by themselves, and an overlay with `context.worldDrawingOffset(of:)` | [Locking](#locking) |
| Change where a drag puts the shapes it moves (snap them, keep them on a grid), and draw while it does | `registrar.translationAdjuster { editor, start in … }`, a `TranslationAdjuster`: Snapping claims it | [The translation adjuster](#the-cores-part-the-translation-adjuster) |
| Ask Claude something (and test it without the network) | `editor.languageModel?.respond(to: ModelRequest(...))`; `ScriptedLanguageModel` in tests | [Language models](#language-models) |
| Keep what a kind's props are bound to right as shapes are deleted and copied (a connector) | `ShapeReferencing` | [Arrows](../Sources/Arrows/ArrowDefinition.swift) |
| Let a kind's shapes be mentioned in text, as pills, with a tab listing what mentions each | `x.mentionable(untitled:symbol:…)` (Mentions), or `registrar.mentionable(K.self)` from a bridge | [Mentions](#mentionable-kinds) |
| Let a kind's text mention shapes, drawn with pills and edited with a picker | A `MentionText` property; `x.mentionText { … }` and `context.drawMentionText`; a `MentionTextView` editor, or `MentionTextArea` in the panel | [Mentions](#mention-text-and-its-stored-form), [In the panel](#in-the-panel-mentiontextarea) |
| Go to what mentions a shape | `mentions.backlinks(of:)`, `showWhatMentions(_:)`; Show What Mentions in the context menu | [What mentions a shape](#what-mentions-a-shape) |
| Restrict what a text may mention to some kinds | `ScopedMentionText<Only<Kind>>`, or a declared scope: `registrar.mentionScope(S.self)` and `x.mentionable(in: S.self)` | [Scopes](#scopes-what-a-text-may-mention) |
| Hold names of shapes that may outlive them (a mention), renamed when copied with them | A value that adopts `ShapeNaming`; `registry.namingKinds` and `record.forEachNamingValue(in:)` to read them | [Values that name shapes](#values-that-name-shapes) |
| Ask what's connected to a shape, and how (arrows, mentions), anywhere in the file | `editor.topology?.neighbors(of:)`, `edges(of:_:types:)` with an `EdgeTypeFilter` | [Topology](#the-index-topologyindex) |
| Say that a kind's shapes connect others: a new kind of edge | An `EdgeType`, `registrar.edgeType(T.self)`, and a source: `x.edges { … }`, `registrar.edges(K.self)`, or `registrar.edges(in: P.self, as: T.self)` over an added property that names shapes | [Topology](#sources) |
| Ask which shape a shape is inside (the owner of its board, at any depth) | `editor.topology?.parent(of:)`, `ancestors(of:)`, `isInside(_:_:)` | [Containment](#containment) |
| Read edges and containment off the main actor, as they were at one instant | `topology.snapshot()`, a Sendable `TopologySnapshot` | [A snapshot for other threads](#a-snapshot-for-other-threads) |
| Find the shapes of a file a query matches (by kind, title, attribute, what's inside what, what connects to what), from a plugin or an agent | `editor.queries?.run(QueryRequest(#"sticky-note:mentions("Auth")"#))`, answered off the main actor; `canvas query` | [Queries](#queries) |
| Give queries a plugin's word (a pseudo-class, or a relation over its edges), or say how its text reads in them | A bridge: `registrar.queryPseudoClass`, `queryRelation` or `queryTextFormat` | [What plugins add](#what-plugins-add) |
| Put an editing view's selection where the press that began editing was | `editor.beginEditing(id, at: point, clickCount:)`, read as `EditContext.startPoint` and `startClickCount` | [Capabilities](#capabilities) |
| Name an undo step, or make several changes one | `editor.transact("Name") { ... }`; `editor.undoHistory.group("Name") { ... }`; `transact(coalescing:)` for a run of writes | [Undo](#undo) |
| Put a service's state back with undo (a selection) | `UndoParticipant` | [Undo](#undo) |
| Change the board for an agent, without starting what follows a person's edits (a sync) | `transaction.byAgent = true`; a service reads `changes.byAgent` | [The command line](#draw) |
| Keep something about any shape beside its props (where it came from) | A `ShapeMetaKey`, and `record.meta[Key.self]` | [Metadata](#metadata) |
| Add a right-click item that isn't one shape's, in every menu and on empty canvas | `registrar.contextMenuForCanvas { ... }` | [The clipboard](#the-clipboard) |
| Show a shape's state in the panel: at its foot, or in a tab that shows while there's something to say | `registrar.detailStatusForEveryShape`, with `in: SomeTab.self` for a tab | [ValidationDetails](#a-tab-of-status-lines-from-a-bridge-validationdetails) |
| Show a shape's state at a glance in the table of contents: a dot or a symbol on its row | `registrar.contentsMarkForEveryShape` | [ValidationContents](#marks-validationcontents) |
| Change a shipped kind's props | A migration in its `static let migrations`, and a fixture for the new version | [Boards on disk](#boards-on-disk) |
| Move a kind's own member onto an added property | `PropsMigration.handOver("title", to: TitleProperty.self)` in the kind's migrations | [StickyNotes](#boards-on-disk) |
| Change how an added property's value encodes | A `PropertyMigration` in the property's `migrations`, and a fixture in `Fixtures/added` | [Boards on disk](#boards-on-disk) |

The rule of thumb: behavior intrinsic to a kind is a [capability](#capabilities), a protocol its
definition adopts; behavior any plugin can add to any kind is an extension point.

## Horizontal and vertical

A **vertical** plugin is a feature: a shape kind and the tool that places it, or a tool on its own.
Sticky notes, arrows, schema cards, subboards, rectangles, polylines and the eraser are verticals.

A **horizontal** plugin is a concern that cuts across kinds. It declares an extension point, and any
kind can take part by contributing to it. Validity is the canonical example: *a shape can be valid
or invalid* is horizontal; *a schema card that isn't JSON is invalid* is one vertical opting in. Titles are
another. The horizontal owns the contract, the engine, and whatever it draws. Shapes never know
they're invalid; the validation plugin outlines them.

A horizontal can also be a feature that individual shapes opt into, and that shows up in the
[detail panel](#the-detail-panel) as a tab of its own, and in the [context menu](#context-menus).
Getting around a file's [boards](#boards) is the example: one line,
`sub.opensBoard(placeholder:systemImage:)`, makes every subboard open onto the board it owns, with
a Board tab in the panel and Open first in the context menu. Boards owns opening them, going back
up, what a board is called and the path that shows where you are; the kind declares nothing, and
the core only holds the boards and shows one. One horizontal may build on another: Boards imports
ContextMenus, DetailPanel, Keyboard, Selection, TableOfContents and Titles.

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
kind's text can hold mentions, while Mentions owns the stored form, the pills, the picker, what
mentions each shape and what keeps them in step with the shapes they name. So is what connects and contains what:
[Topology](#topology) keeps the file's graph of edges (an arrow bound at both ends, a mention),
typed by the plugins that own what each means and read out of the shapes that carry them, while
Ports and Mentions only say what their shapes carry. So is finding shapes: [Queries](#queries)
answers a query about the whole file (kinds, attributes by their schemas, what's inside what, what
connects to what), while the plugins that own a concern say through bridges what shapes are called
and what more a query may ask. And a horizontal may declare no point at
all and only lend something:
[LanguageModels](#language-models) lends every editor the model plugins ask.

Opting in goes in one of two directions:

- **The vertical imports the horizontal** and contributes from inside its own `register`.
  Schemas does this for Validation: `schema.validate { ... }`.
- **A bridge imports both**, and neither knows the other. `RectangleTitles` gives rectangles a
  title, though Rectangles has never heard of titles and Titles has never heard of rectangles. A
  bridge may join two horizontals: `ValidationDetails` shows each shape's validation issues in an
  Issues tab of the detail panel, and `ValidationContents` marks their rows in the table of contents, though
  Validation has never heard of either, nor either of validity. `TitleNames`, `PortEdges` and
  `ValidationChecks` give [`canvas draw`](#the-command-line) its names, edges and warnings, though
  Automation has never heard of titles, ports or validity, and `MentionValidation` warns
  about mentions that can't work, though Mentions has never heard of validation, nor Validation of
  mentions. `ArrowPorts` makes arrows what a drag from a port draws, and names their family of edges, though Arrows has never heard
  of a
  channel or an edge, nor Ports of an arrow. `TitleQueries`, `BoardQueries`, `MentionQueries`,
  `ValidationQueries` and `SelectionQueries` give [queries](#queries) shapes' names, boards' names
  and words (`:mentions`, `:invalid`, `:selected`), though Queries has never heard of titles,
  boards, mentions, validity or the selection, nor any of them of queries.

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
.target(name: "StickyNotes", dependencies: ["Canvas", "DetailPanel", "Keyboard", "Mentions", "Ports", "Selection", "TableOfContents", "Titles"]), // layer: vertical
.target(name: "RectangleTitles", dependencies: ["Canvas", "DetailPanel", "Rectangles", "Titles"], path: "Examples/RectangleTitles"), // layer: bridge
```

| Layer | May depend on | Modules |
|---|---|---|
| wire | wire | CanvasRPC (what the app and its [command line](#the-command-line) say to each other) |
| foundation | foundation | Geometry, Canvas (the core), and pure libraries beneath the plugins that know no plugin: DrawScript (the language [`canvas draw`](#draw) reads, and its solver) and QueryLanguage (the language [`canvas query`](#query) reads) |
| ui | foundation, wire | CanvasUI (the AppKit view, the SwiftUI toolbar, `CanvasFocus`, and the command line's server) |
| horizontal | foundation, horizontal, wire | Keyboard, Selection, Validation, Titles, DetailPanel, ContextMenus, TableOfContents, Adornments, Clipboard, Locking, Ports, Mentions, Topology, Queries, Automation, QueryCommands, LanguageModels, Boards, Snapping |
| vertical | foundation, horizontal | Arrows, StickyNotes, Schemas, Subboards, Rectangles, Polylines, Eraser, Reordering |
| bridge | foundation, horizontal, vertical | RectangleTitles, ValidationDetails, ValidationContents, MentionValidation, ArrowPorts, TitleNames, PortEdges, ValidationChecks, TitleQueries, BoardQueries, MentionQueries, ValidationQueries, SelectionQueries |
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
  added property, channel or edge type id as a string literal (`kind == "sticky-note"`) without
  depending on it fails. An id is a module's when it declares it as a static `ShapeKind`, `ToolID`,
  `PluginID`, `PropertyKey`, `ChannelID` or `EdgeTypeID` (`static let id: ChannelID =
  "note-link"`), or as its plugin's `id`. A string two modules declare is both of theirs, so a
  module that writes it depends on both: an id that must equal another module's takes it from that
  module's constant rather than declaring it again (`ArrowEdge.id` is the arrow kind's name,
  [Topology](#types)). A kind's own property names (`Property("title", ...)`) are only that kind's, so they're
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
- **No shadowing names.** A public type named like a module fails, and so does a public `Task` or
  `Span`, which would shadow Swift's in every module that imports it (a query's place in its text is
  a `QuerySpan` for that reason).
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
  | `indicatorPath(of:in:)` | the geometry's outline (the target hint, and hover and selection outlines, drawn in full; zoomed out, [the skeleton's](#skeletons)) |

  `geometry` is the one source of truth. Override it and hit testing, the outline, the marquee,
  arrows, the minimap (which draws each shape as a silhouette of its outline) and the shape zoomed
  out (the core's default [skeleton](#skeletons), unless the kind draws its own) all follow.
  Override `hitTest` or `indicatorPath` only when you can do better: a sticky note outlines its
  rounded corners (`indicatorPath`), and a line is hit only near its stroke (Polylines' `hitTest`).
  A `hitTest` that reaches past the outline (a stroke, a few points of slop) says how far in
  `hitMargin`: the editor asks it only about points that near. A kind that knows better than its
  geometry whether the marquee touches it (Arrows, against its arc) adopts Selection's
  `BrushHitTesting`.
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
  which selects the new shape), and lets it follow the pointer until release (`PlacingSession`, which
  snaps as any drag does); Escape before the release takes it away and selects again what was
  selected before the press, so the press comes to nothing.
  `editingPlacement` follows the pointer too, and opens the shape for editing on the release (a
  click's, at once), and exists only for `Editable` kinds, a restriction the compiler checks. Any tool or gesture can also insert a shape itself, with
  `editor.transact { $0.insert(record) }`, as a port's drag does its arrow.

What a real vertical adds on top ([StickyNotes](../Sources/StickyNotes/StickyNotes.swift)):

```swift
registrar.shape(StickyNoteDefinition()) { note in
    let place = note.editingPlacement(size: NoteStyle.size) { StickyNote() }
    note.tool(label: "Note", systemImage: "note.text", shortcut: "n", placing: place)   // and N, with Keyboard
    note.createOnDoubleClick(place)          // opts into Selection: double-clicking empty canvas places a note
    note.title()                             // opts into Titles: a title Titles keeps, its pill, and its row's name
    note.details(header: { $note in TitleHeader($note) }) {}      // renamed in the panel's header
}
```

A note is as tall as its text, and never shorter than a new one's 200 points (tldraw's note grows
the same way): `NoteStyle.fittedHeight(of:width:keeping:)` measures the text as the render draws
it, pills and all, with string drawing, and the note's editor writes the height in the same update
as the text (`textDidChange`), so growing is part of the typing's step; its text view grows with
the editor the canvas lays over the note. A note made or given text from properties is fitted too
(`DerivedProps`, each mention measured by the name it holds), so `canvas draw` places it as tall as
it is; a board read keeps what it saved.

The note's render draws its text with string drawing (`NSAttributedString.draw`), and its editing
view is a TextKit 2 `NSTextView` laid over it, which the canvas scales by the zoom; the two must
put the text on the same lines, or it moves when editing starts. Both take
`NoteStyle.textAttributes`, whose paragraph fixes every line at 19 points (`NoteStyle.lineHeight`):
string drawing's own pitch for the font, so the render is as it was, where TextKit 2 would set the
lines 18 points apart. At the same height TextKit 2 sets a line's glyphs a point lower in it, so the
editor's text starts a point higher, 15 points down (`NoteStyle.editorInset`), and its lines fall
on the render's, pixel for pixel but anti-aliasing, as typed text does too (StickyNotesTests).

Zoomed out, a note is its [skeleton](#skeletons) ([NoteSkeleton.swift](../Sources/StickyNotes/NoteSkeleton.swift)):
its frame in its yellow, square (its 4-point corners are under a point and a half on screen there)
and without the shadow, and its text greeked, a bar where each line would be (the core's
`SkeletonTextBars`, over its text's runs, handed to `fillSkeletonText` as they're worked out, which
a schema card's description goes by too): two fills, whatever it says. The lines are
counted, never laid out: a line holds the box's width at 0.52 em a column, as
`SkeletonText.columns(of:)` counts them (a CJK character or an emoji two, a mark none, a scalar a
zero-width joiner joins nothing; calibrated once against string drawing, which put a dozen typical
notes on 55 lines where this counts 56; glyphs alone average 0.46 em, but words wrap early), so a
paragraph in Japanese takes the lines the render gives it; a mention counts as wide as its pill, by
the name it holds (its target isn't looked up), its label in columns, read only as far as a pill
grows (a pill is 30 columns at most); a paragraph (ended by a line feed, a return, or both) with nothing that
shows (empty, or spaces) is a blank line; and there are no more lines than the box holds (100,000 at
most, so a note of any height a file edited by hand keeps, 1e21, counts them in an `Int`). Each bar
covers its line's x-height, 6.5 to 15 points down its 19, as wide as the box but for a paragraph's
last, as long as what's left of it (two columns at least). So it can be a line off the text where
words wrap unusually, and a little more in a script set narrower or wider than its columns (Hangul,
emoji). What it reads is bounded by the box, not the text: a paragraph that shows is read only until
it fills the lines left, since every bar after that is the box's width, so a paragraph of a million
characters costs what one that fills the box does; and text typed in the app, still the UTF-16 the
text view cut it from until the board is read again, is read 64 code units at a time on the stack,
never transcoded.

## Tools and sessions

A **tool** handles what happens before a press: hover, the press itself, and which cursor to
show. It's a class with one instance per editor, so it can keep state. A **session** owns one
press-drag-release. It lives on the editor, not the tool, so it outlives tool switches. A place tool
switches back to the default tool and keeps dragging its new shape.

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
  while it runs, like a marquee, above the world overlays), `scrollsAtEdges` (the canvas scrolls
  while the pointer is at its edge or past it, tldraw's edge scrolling, and the session hears a drag
  where the pointer is whenever the camera moves: below). A session can hand over to another by
  setting `editor.session` (pressing an arrow handle becomes dragging it). A session that sets
  `editor.hintedShapeID` clears it when it ends.
- **Scrolling at the edges** is tldraw's (its EdgeScrollManager and options), for a session that
  asks (`scrollsAtEdges`: `TranslatingSession`, and so a placed shape following the pointer;
  Selection's marquee; a connection drawn from a port, ArrowPorts'): once the pointer has gone past
  the drag threshold from the press, while it's within 8 view points of an edge of the view or past
  it, for longer than 200 ms, the camera pans that way a frame (16 ms) at a time, at 25 view points
  a 60 Hz frame at the edge or past it, less further in, eased in (a cubic) over the next 200 ms, and
  at 0.612 of that along a side of the view under 1,000 points. Off every edge it stops, and the
  delay starts over. The session hears a drag where the pointer is on every frame, and on any other
  move of the camera mid-drag (a scroll, a pinch), so what it drags stays under the pointer (tldraw
  dispatches a pointer move on every camera change); the pointer's velocity isn't sampled for it.
  Where it isn't tldraw's: every edge scrolls within its 8 points (tldraw scrolls at an edge that
  meets other UI only past it; a Mac's pointer goes past any edge of a window); frames are nominal,
  as the camera's slide's are; and a connection drawn from a port scrolls, where tldraw's handle
  drags don't (an arrow's handle, dragged, doesn't here either), so a shape off screen can be linked
  to without zooming out. The Hand never does: it pans.
- **The default tool** is where the editor starts, and where Escape and placing a shape return. One
  plugin may claim it (`registrar.defaultTool(.select)`, as Selection does); without a claim it's
  the Hand. Claiming a tool nobody registers is `RegistryError.invalid`.
- **Escape** (Keyboard's key for `editor.cancel()`) goes to the running session (`cancel`), else to
  the tool (`cancel`), else back to the default tool. Escape while shapes move with the pointer
  (`TranslatingSession`) puts every one back where it was when the drag began (tldraw's behavior):
  a lone box, a selection, an arrow (its precise ends included); a shape just placed, still
  following the pointer, is taken away, and what the undo participants kept before the press (what
  was selected) comes back, as undoing the step would, so the press comes to nothing (tldraw's
  cancel goes back to its mark, selection and all). What others committed meanwhile stays.
- **Where a drag puts what it moves** is under the pointer, unless a plugin claims the [translation
  adjuster](#the-cores-part-the-translation-adjuster): Snapping, in the shipped app, snaps it to the
  shapes in view, and draws its guides with the session. While ⇧ is held (from the press or once
  the drag is under way, pressed or let go at once), it keeps to one axis, the one the pointer has
  come further along since the press (tldraw's), and stays where it began along the other; at the
  press, ⇧ is still the select tool's, adding to the selection.
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
- **Commands** (`CanvasCommand`: `.delete`, `.selectAll`, `.goBack`, `.cut`, `.copy`, `.paste`,
  the zoom commands, …)
  are what menu items run: the canvas view forwards Edit › Delete and Edit › Select All (AppKit's
  standard actions) with `editor.perform`, and dims them as `canPerform` says, the board's window Go › Back (⌘[) and View's zoom items whatever has the
  keyboard, and Edit › Cut, Copy and Paste wherever text doesn't take them first, and a key or any
  plugin may run one. A plugin claims each with `registrar.command`, or with Keyboard's
  `registrar.command(_:shortcuts:)`, which gives it its keys too, and may say when it can run
  (`isEnabled:`), which `editor.canPerform` asks for a menu item to enable it, and a key to take
  the stroke; unclaimed, or unable to run, `perform` returns false. A view that asks it redraws as
  what it read changes: `editor.session` is observed as a press starts and as it ends (not as one
  session hands over to another), so a control enabled only between presses comes back once the
  press that selected its shape is let go.
- **The secondary click** (a right-click, or a Control-click) opens whatever menu the one plugin
  that claims it makes (`registrar.menuForSecondaryClick`), ContextMenus in the shipped app;
  unclaimed, or nil, the click does nothing. AppKit offers a Control-click to the menu first; with
  none, it reaches the tool as a press with `pointer.isControlClick` set (exact, unlike `modifiers`,
  which count ⌃ let go in the last 150 ms). The select tool ignores it, since it's the secondary
  click there; any other tool takes it as a press with ⌃ held (the hand tool pans).
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
  geometry, no placements, and no every-box sections in the detail panel (`detailsForEveryBox`).
  The core culls it by its geometry, as it culls a box by its frame.
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
- **Zoomed out it's the core's default [skeleton](#skeletons)**, its points a view point wide, in
  its own indigo (`CustomSkeleton`, its code shown there), at the default's cost.

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
`ToolID(placing: Polyline.kind)`, as a place tool's is, so a line is called after the tool
(`registry.label(of:)`): "Line", with the tool's symbol, in the detail panel's header and its row.

[Arrows](../Sources/Arrows/ArrowDefinition.swift) is the full-size version: a kind without a frame
that also has handles (`HandleProviding`), an exact marquee test (`BrushHitTesting`), a paint order
of its own (`PaintOrderAnchored`), and a translation that keeps its bindings. It lends other
plugins two things, and knows nothing of why ([ArrowConnecting.swift](../Sources/Arrows/ArrowConnecting.swift)):
rules for what an arrow's end may bind to (`ArrowBindingRules`, tldraw's canBind), and an arrow
drawn for a gesture of theirs (`editor.beginArrow`), which is how [ports](#the-connector-arrowports)
draw theirs, the only way a person draws one. No tool places an arrow, so it says what its kind is
called itself:

```swift
arrow.label("Arrow", systemImage: "arrow.up.right")
```

`registry.label(of: kind)` is what a kind is called, and its symbol, wherever a shape is shown by
its kind (the detail panel's header, a row in the table of contents, “Arrow” can’t be mentioned.):
what the kind declares (`ShapeRegistrar.label`, one per kind), else its placing tool's label and
symbol ("Note"), else its id, with no symbol.

Zoomed out, an arrow draws a [skeleton](#skeletons) of its own
([ArrowSkeleton.swift](../Sources/Arrows/ArrowSkeleton.swift)), since its render looks up the
shapes it joins and clips its ends every frame: `ArrowSkeleton` reads only its kept geometry's
three points (its start, the middle of its body, its end) and works nothing out again, drawing the
arc through them, or the line from start to end where the middle is less than a quarter of a view
point off it, in its color as wide as its own stroke but never under a view point, with butt ends,
and each head a filled triangle, as long as the render's chevron and swung as far. A stroke and a
fill. Its outline there is that arc (`CustomSkeletonOutline`), not its geometry's two straight
segments. That departs on purpose from tldraw, whose arrows only trade a drawn style for a solid
one, below 25%, and from the render's round caps and open chevrons, below 35% alone: the POC's
transcript and every render at 35% and above are as they were.

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

    /// A title as everything that shows it reads it: on one line, each run of whitespace a space;
    /// nil when that leaves nothing, so a blank title is no title.
    public static func folded(_ title: String?) -> String? { ... }
}

/// ② The extension point: declared and read by this plugin, filled by others. One title per kind.
public enum ShapeTitles {}

extension ShapeTitles: KeyedExtensionPoint {
    public typealias Contribution = TitleContribution       // a shape's title, whether it's derived, whether it shows a pill, and with its kind's symbol
    public static var owner: PluginID { .titles }
    public static func uniqueKeys(of _: TitleContribution, for target: ShapeTarget) -> [AnyHashable] { [target] }
}

/// ③ Sugar, so opting in is one line: `note.title()`.
extension ShapeRegistrar {
    public mutating func title(pill: Bool = true, symbolInPill: Bool = false, contents: Bool = true) {
        optIn(to: TitleProperty.self)                                     // the property, in the kind's schema
        title(pill: pill, symbolInPill: symbolInPill, contents: contents, isDerived: false) { $0[TitleProperty.self] }  // its value
    }

    /// A title derived from what the kind keeps itself: `label.title { $0.props.text }`.
    public mutating func title(pill: Bool = true, symbolInPill: Bool = false, contents: Bool = true,
                               _ make: @escaping @MainActor (ShapeRecord<Definition.Props>) -> String?) {
        title(pill: pill, symbolInPill: symbolInPill, contents: contents, isDerived: true, make)
    }

    private mutating func title(pill: Bool, symbolInPill: Bool, contents: Bool, isDerived: Bool,
                                _ make: @escaping @MainActor (ShapeRecord<Definition.Props>) -> String?) {
        contribute(TitleContribution(Definition.Props.self, showsPill: pill, symbolInPill: symbolInPill, isDerived: isDerived, make),
                   to: ShapeTitles.self)
        if contents { contentsTitle { TitleProperty.folded(make($0)) } }     // TableOfContents' point: the title names the shape's row
    }
}

extension PluginRegistrar {     // for a kind another plugin registers (bridges use these)
    public mutating func title<P: ShapeProps>(_: P.Type, pill: Bool = true, symbolInPill: Bool = false, contents: Bool = true) { ... }
    public mutating func title<P: ShapeProps>(_: P.Type, pill: Bool = true, symbolInPill: Bool = false, contents: Bool = true,
                                              _ make: @escaping @MainActor (ShapeRecord<P>) -> String?) { ... }
}

/// ④ The consumers: lookups, and the pill, an adornment Titles places on every titled shape.
extension Registry {
    public func title(of shape: AnyShapeRecord) -> String? { ... }     // on one line; nil if there's none, or it's blank
    public func titleIsDerived(_ kind: ShapeKind) -> Bool { ... }      // worked out by `title { … }`, not only named
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
        // On every shape whose kind's title shows a pill (not `pill: false`): its title, after the
        // kind's symbol if it asks (`symbolInPill`), or none.
        registrar.adornmentForEveryShape(TitlePill.self, where: { $0.registry.showsTitlePill($0.kind) }) { shape, context in
            context.registry.title(of: shape).map { AdornmentLabel($0, systemImage: context.registry.titlePillSymbol(shape.kind)) }
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
title kept as it is. A kind that stores a title of its own would have none of that, so notes hand
theirs over ([Boards on disk](#boards-on-disk)).

A title may be derived instead, from what the kind keeps itself: then it isn't data, and isn't in
the schema. A [schema card](#schema-cards)'s is its schema's `"title"`
(`schema.title(symbolInPill: true) { … }`), so there's one place to say it. A kind may be both: a bridge
opts it into the title Titles keeps and derives one for the shapes nobody named,
`TitleProperty.folded(shape[TitleProperty.self]) ?? what it derives` (TitlesTests' discs; no
shipped kind is both).

`registry.titleIsDerived(kind)` tells the two apart: true for a kind titled by `title { … }` (a
schema card), false for one titled only by `title()` (a note) or not at all; a kind that can be
named opts into `TitleProperty`, so `registry.properties(for: kind)` has its key. The smallest
bridge, [`Examples/RectangleTitles`](../Examples/RectangleTitles/RectangleTitles.swift), is one
line, `registrar.title(Rectangle.self)`: rectangles can be named, and an unnamed one has no title;
a second puts `TitleHeader` in the detail panel's header. The header is a function, not a
closure: a closure would be built by SwiftUI's `ViewBuilder`, and a file that imports SwiftUI to
have it sees SwiftUI's own `Rectangle` beside the kind. Every kind a tool places in the app can be
named, which is what [`canvas draw`](#draw) needs, since titles are the only names it has, and
renamed or cleared by a person in the panel, since a name a script gave is theirs to change too.

Either way, a shape may have none: nil or blank is no title. However it's written, a title reads
on one line wherever it shows (each run of whitespace folds into a space: `TitleProperty.folded`),
so the lookup, the pill and the row agree, and so does whatever matches titles (`canvas draw`
folds the titles a script writes the same way, and `canvas query` those a query writes). A title
that reads as it's written already (ASCII, no whitespace but single spaces between words, as most
are) comes back as it is, checked a byte at a time, so a query that reads every title in the file
splits and joins none of them. What a title brings:

- **A pill** at the left end of the row just above the shape (18 points tall, 9 above the top edge):
  one line, as long as the title and no longer than the row leaves it, where a longer title ends in
  "…". The row is the shape's width, less what's at its right end (a [lock](#locking)) and 4 points
  before it, so locking a note with a long title shortens its pill by 22 points, until the lock has
  gone; with under 30 points left (44 with a symbol before the title), there's no pill. The pill is `TitlePill`, an
  [adornment](#adornments): Titles places it on every shape whose kind's title shows one, though it
  defines no kind, and Adornments lays it out with whatever else the shape shows, so it never meets
  the lock. It keeps its size on screen, shrinking with the shapes below 25% zoom, is a blank
  capsule below 35% on a shape drawn as a [skeleton](#skeletons), as long as the title's columns (a
  CJK character or an emoji two), and in full on the shape being edited
  ([adornments zoomed out](#the-label)), goes where its shape is drawn (it shakes with a locked
  shape), and is its shape's for the pointer: a click on it
  selects the shape, a drag moves it, and a double-click edits a note. A kind that draws its title
  itself leaves it out: `sub.title(pill: false)`. A kind whose look alone doesn't say what it is
  puts its symbol (`registry.label(of:)`, its tool's) before the title: `symbolInPill: true`, as the
  schema card's `{}` (`curlybraces`), small and a little softer than the text; the capsule is longer
  by the symbol's place, blank too ([the label](#the-label)).
- **Its row's name** in [the table of contents](#the-table-of-contents), through TableOfContents'
  `ContentsTitles`, which names a kind's rows without replacing them: a titled note is listed by
  its title; an untitled one by its text, as before. `contents: false`
  leaves the kind's row as it is.
- **A rename in the detail panel**, for a kind that wants one: [`TitleHeader`](#renaming-in-the-header-titleheader),
  which the kind puts in its header.

So Titles builds on three horizontals: it imports Adornments, TableOfContents
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
  `editor.revision` changes and is cached otherwise. It checks the board shown, and keeps what it
  found on the boards shown last in a `BoardStash`, so going back to one checks nothing
  ([Showing a board](#showing-a-board)).
- **Something small shown on a shape is an [adornment](#adornments)**, laid out with the rest so
  none overlaps another, as Titles' pill is. Anything else a horizontal draws (an outline around
  the shape, as Validation's) is an overlay, `registrar.overlay`, above every shape. World overlays
  draw with the camera transform; view overlays draw in view points.
- **Data on the shape is an added property.** A concern that gives each shape something to hold
  (Titles' title) declares a `ShapeProperty`, and its sugar opts the kind in
  ([Properties](#added-properties)). Its extension point then holds only how the kind takes part:
  `ShapeTitles` says how its shapes' titles read and whether the canvas shows the pill.
- **Contracts should be pure.** Validation rules read the document only through
  `ValidationContext`: `shape(_:)`, a lookup the engine notes, so a change to a shape checks again
  only that shape and those whose rules looked it up; and `registry`, which never changes, so
  reading it (which kinds can hold names, which can be mentioned) is no lookup. Design your
  contexts the same way.

[Validation](../Sources/Validation/Validation.swift) is the full-size version of the same pattern:
per-kind rules, rules for another plugin's kind, rules for every kind, an engine, and an overlay.
Its model is ESLint's: a rule finds issues on a shape, each an error or a warning, two channels of
one thing (`.error("A schema must be a JSON object.")`, `.warning("“age” is required, but isn’t a property.")`). An error makes
the shape invalid; a warning only flags it. Validation has one rule of its own, for every kind:
each place a shape breaks its kind's schema is a warning, about the property it's in
([Checking shapes](#checking-shapes-against-their-schemas)). The overlay outlines a shape with issues in its worst
one's color, red for an error and orange for warnings alone, and a shape without issues not at
all, nor one being edited, whose text is still being written. In full, each ring is stroked alone
and follows the shape's own outline, 3 view points out, as a selection's follows it: the outline
the core strokes for its kind (`registry.indicatorPath(of:in:)`, which any overlay that decorates a
shape along it reads) grown by the padding, so a card's ring keeps its rounded corners and an
arrow's hugs its line. Growing an outline is path arithmetic, so each shape's ring is kept until the
shape or its outline changes, or the zoom by more than a tenth (a pinch grows it once a tenth, not
every frame), and a shape under 32 points on screen gets a rounded rect around its bounds, which
looks the same there. Zoomed out, where shapes are [skeletons](#skeletons), the rings are a map of
where the problems are. There, with thousands in view, each is a ring around its bounds with square
corners, grown from no outline, and a run of one color, in paint order, is filled as one path, so a
front shape's ring still covers a back one's: Core Graphics fills rects in one path for a fraction
of what stroking each costs (4,800 at 10%: 2.7 ms, against 21), while rounded outlines in one path,
stroked or filled, cost ten times what each stroked alone does. Two bridges show the issues
elsewhere, though Validation has never heard of either place: the
detail panel lists a shape's issues in an Issues tab
([ValidationDetails](#a-tab-of-status-lines-from-a-bridge-validationdetails)), and the table of
contents puts a dot of the same color on the row of each shape with issues, so the board's are
found at a glance and a click goes to one ([ValidationContents](#marks-validationcontents)). A
third adds rules: [MentionValidation](#warnings-mentionvalidation) warns about mentions that can't
work. Outside the engine, `registry.validationIssues(of: record, in: shapes)` runs every rule for a
shape's kind against any `ShapeContext`, a transaction's mid-way included (the rules look other
shapes up in it): it's how [`canvas draw`](#what-draw-takes-from-other-plugins) warns about what
it's drawing before it commits (ValidationChecks, a fourth bridge).

`editor.validation?.cachedResult(for: id)` is a shape's verdict as the engine holds it, checking
nothing (`CachedVerdict`): `.current(result)` (nil for no issues) for a shape on the board shown,
once the engine has heard every commit and read that board, while the shape isn't waiting to be
checked again (it changed or moved, or a shape its rules looked up did); `.unknown` otherwise, where
only running its rules can say (`validationIssues(of:in:)`). It never runs a rule, so it's for a
reader that mustn't make the engine read a board (`result(for:)` checks every shape that's waiting,
or a whole board it hasn't read, in one turn): a query's `:invalid` and `:warned`, asked about many
shapes in slices ([ValidationQueries](#what-plugins-add)), take it where it's current and run the
rules where it isn't. ValidationTests' CachedResultTests hold it, counting rule runs, with a service
that hears each commit before the engine.

A drag commits every shape it drags, on every event, so a rule whose issues follow from what
shapes are, never where, says so, and a drag doesn't run it:

```swift
registrar.validateEveryShape(ignoringMoves: true) { shape, context in ... }   // x.validate(ignoringMoves:), registrar.validate(P.self, ignoringMoves:)
```

A commit that only moves shapes (`ChangeSet.moved`: `Transaction.moveBox`, which a drag and
`translate` use) runs such a rule for none of them, neither the shapes it moved nor those whose
rule looked one of them up, and each keeps what the rule found last (the engine keeps it per shape
and per rule, so a shape's issues stay in its rules' order); the other rules run as they always
do. Validation's schema rule ignores moves, and so does MentionValidation's, so a drag of a
subboard 100 notes mention checks none of them again. A rule that measures distances, or finds overlaps,
must not.

## Properties

A shape's data is its properties. Most are its kind's own, which the kind lists. Others are added
by a plugin to the kinds that opt in, as Titles adds a title. Both are typed, saved with the
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

(A note's title and whether it's locked are properties too, the ones Titles and Locking add to it:
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
  nil optional's, and one that varies from one `init()` to the next (a new id each time, as an item
  in a list may have), which the schema states no default for. `required()` means there's none: a
  board, or anyone writing one, must give it. Only those are `required` in the schema. Every shipped
  box kind's `frame` is one.
- **Modifiers** add JSON Schema keywords: `title`, `description`, `minimum`, `maximum`,
  `minLength`, `maxLength` (both in code points, as JSON Schema counts), `pattern`, `minItems`,
  `maxItems`, `examples`, `deprecated()`, `readOnly()`, and `keywords([...])` for any other
  (`.keywords(["multipleOf": 0.5])`). A schema card's `schema` property ends in
  `.keywords(["contentMediaType": .string("application/schema+json")])`, and Titles bounds a title
  with its property's `keywords`, `.minLength(1).maxLength(80)`. A bound says what a shape's value
  should be, not what it can be: nothing refuses a value outside it, and Validation warns about the
  shape ([Checking shapes](#checking-shapes-against-their-schemas)). The modifiers are
  `PropertyModifiers`, which an added property's `keywords` take too.
- **A string enum** adopts `SchemaCases` and titles its cases (`schemaTitle`): its schema is
  `oneOf` a `const` per case, with its title.
- **A struct in the props** is `SchemaDefined` too, with a list of its own (Arrows' `ArrowBinding`),
  written out where it's used. Given a name, it's a shared definition instead, which each use refers
  to: CanvasTesting's `Properties<MemoNote>(definition: "memo-note")` is `canvastesting.memo-note`
  in a schema, named after the module that declares the type, so a type has one name wherever it's
  described, and two modules' definitions never collide. A struct that holds itself (a tree) needs a
  name, and its definition then refers to itself.
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
once ([Titles](../Sources/Titles/Titles.swift)):

```swift
public enum TitleProperty {}
extension TitleProperty: ShapeProperty {
    public static let key: PropertyKey = "title"
    public static var defaultValue: String? { nil }
    public static var keywords: PropertyKeywords<String> {
        PropertyKeywords().description("What the shape is called.").minLength(1).maxLength(maxLength)
    }
    public static func isNone(_ title: String) -> Bool { title.allSatisfy(\.isWhitespace) }
}
```

- **`key`** is where boards keep its values, and its name in each kind's schema. It's unique among
  added properties, never one of an opted-in kind's own property names, and never changes once
  shipped. The id audit holds a `PropertyKey` literal to the module that declares it, as it does a
  kind ([The module graph](#the-module-graph)).
- **`defaultValue`** is what every shape of a kind that opts in has until it's changed (a flag's
  `false`, [below](#something-the-user-turns-on)). Nil, as a title's is, means only the shapes it's
  set on have one, and setting it to nil removes it.
- **`keywords`** is what its schema says beyond its value's type, in the modifiers a kind's own
  properties take (none by default). A title is one to 80 characters (`TitleProperty.maxLength`),
  and a shape whose title is longer gets a warning ([Checking
  shapes](#checking-shapes-against-their-schemas)).
- **`isNone(_:)`** says which values are no value at all (never, by default): a title's says a
  blank one. No shape holds one: setting one sets nil, or the
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
registrar.declare(TitleProperty.self)                       // the owner, TitlesPlugin; one plugin per key
note.optIn(to: TitleProperty.self)                          // a kind, inside registrar.shape { note in ... }
registrar.optIn(Rectangle.self, to: TitleProperty.self)     // another plugin's kind, from a bridge
registrar.optInEveryShape(to: P.self, where: { !($0 is any PaintOrderAnchored) })   // every kind, or those a definition picks
```

A kind opts into a property once: its own opt-in and an every-shape one can't both hold. It rarely
calls `optIn(to:)` itself: the horizontal's sugar does, and brings the rest. `note.title()` opts
the note in, then contributes to Titles' point, which brings the pill and names the note's row
([Titles](#a-horizontal-plugin)); Locking opts every kind into `locked` with `optInEveryShape`
([Locking](#locking)).

**Reading and writing.** A shape's value is `record[TitleProperty.self]`, on an
`AnyShapeRecord` or a typed `ShapeRecord<StickyNote>`, beside its props; nil if it has none. It
changes as the props do, in a transaction:
`tx.update(id) { $0[TitleProperty.self] = "Plans" }`. What a plugin derives from both reads
the record: a note is mentioned by its title, else its text's first line
(`registry.mentionAppearance(of:)`).

- **Writes that can't hold are dropped**, as a frame that isn't finite is: a value set on a kind
  that doesn't opt in, nil for a property with a default, and anything set on a value or a shape
  kept aside ([Boards on disk](#boards-on-disk)). Setting the value a shape has commits nothing.
- **Defaults are filled in where shapes enter an editor**: an insert (placing, pasting, with the
  boards `insert(_:contents:)` brings), `CanvasEditor.init` and `replaceFile` (on every board of the
  file), `replaceDocument`, and reading a board. Filling them adds no commit of its
  own and never marks a board edited: `init` commits nothing, `replaceFile` (and so opening a
  board) makes its one commit with the defaults in it, which services hear but which doesn't mark
  the board edited, and an insert is an edit anyway. `registry.fillingDefaults(document)` does the
  same to a document.
- **Copies keep them**: `record.copy(as:)` takes the values along, as it does the metadata.
- **A placement can set one** on what it places:
  `placement(size: size) { Rectangle() }.setting(TitleProperty.self, to: "Zone")` would name every
  rectangle its tool places "Zone".

**The registry** refuses an opt-in to a property no installed plugin declares, two declarations of
one key, a kind opted in twice (by one plugin or two), and a kind opting into a property named like
one of its own:

```
PropertyOptIns: ratings opts box into property stars, which no installed plugin declares
ratings and more both claim box's stars in PropertyOptIns
PropertyOptIns: rated has a property of its own named stars, so it can't opt into the one ratings declares; hand the member over to it (PropsMigration.handOver), or rename one
```

Its report shows each declaration and opt-in: `property title` on the owner's line (`property
title v1` once it has a migration), `property title → sticky-note` on the line of the plugin
that opts a kind in, and `property … → every shape` for `optInEveryShape`. In code,
`registry.declaredProperties`, `registry.properties(for: kind)` (in plugin order) and
`registry.owner(of: key)`.

**In the panel and the menu.** DetailPanel and ContextMenus take sections and items over an added
property's value:

| Sugar | For |
|---|---|
| `x.details(of: P.self) { sections }` | Sections over the value, on this kind's shapes that have one: what a horizontal's sugar contributes for the property it opts the kind into. |
| `registrar.details(of: P.self) { sections }` | The same, on every shape that has one, whatever its kind. |
| `x.contextMenu(of: P.self) { items }`, `registrar.contextMenu(of: P.self) { items }` | Items over the value, on this kind's shapes, or every shape, that have one (a flag's Flagged, [below](#something-the-user-turns-on)). |

A section gets a `ShapeBinding` of the value (`$flagged`, a `ShapeBinding<Bool>`), and
each write is one transaction on that shape's value; an item edits it in place
(`{ $0.toggle() }`). A kind's own sections and header read an added value through the
shape the panel drew: `$note.shape[TitleProperty.self]`, and bind one, nil while the shape has
none, with `$note[TitleProperty.self]` (a `Binding<String?>`: `TitleHeader($note)` renames through
it) ([`ShapeBinding`](#reading-and-writing-shapebinding)).

### A kind's schema

`registry.schema(for: kind)` is a kind's properties as one JSON Schema (draft 2020-12): an object
with each of its own properties, then each added property it opts into, marked with its owner
(`x-canvas-owner`) and its default, if it has one; only properties marked `required()` are
`required`, and nothing else is allowed. A kind whose shapes own boards (`BoardOwning`) is marked
`"x-canvas-board" : true`.
Shared definitions are under `$defs`, named after the modules that declare them (`core.rect`, `mentions.text`,
`arrows.terminal`), and every `$ref` is local. The sticky note's, abbreviated (CompositionTests pins
it whole):

```json
{
  "$defs" : {
    "core.rect" : { "description" : "[[x, y], [width, height]], in world units", "type" : "array", "prefixItems" : [ … ], … },
    "mentions.text" : { "contentMediaType" : "text/x-canvas-mentions", "description" : "Text that may mention shapes. …", "type" : "string" },
    …
  },
  "$id" : "tag:infinite-canvas,2026:kinds/sticky-note",
  "$schema" : "https://json-schema.org/draft/2020-12/schema",
  "additionalProperties" : false,
  "properties" : {
    "frame" : { "$ref" : "#/$defs/core.rect" },
    "locked" : { "type" : "boolean", "x-canvas-owner" : "locking" },
    "text" : { "$ref" : "#/$defs/mentions.text", "default" : "", "description" : "What the note says." },
    "title" : { "description" : "What the shape is called.", "maxLength" : 80, "minLength" : 1, "type" : "string", "x-canvas-owner" : "titles" }
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

**Text reads a kind's schema through the core's `KindSchema`**
([KindSchema.swift](../Sources/Canvas/Schema/KindSchema.swift)), so [`canvas draw`](#draw) and
[`canvas query`](#queries) read a value alike. It holds the schema's JSON and no registry, so it's
`Sendable` and reads anywhere (a query's vocabulary keeps each kind's), and it follows the
schema's `$ref`s within it (`#`, `#/$defs/<name>`, the name a pointer's step, percent-encoded):

- **What a property is**: `holdsPlace(_:)`, whether it says where a shape is (its schema is, or holds,
  the core's rect or point, never judged by name; a size doesn't), and `shape(of:)`, what its values
  are (`KindSchema.PropertyShape`: `.string(format:mediaType:choices:)`, `.number(integer:)`,
  `.boolean(default:)`, the schema's default, else false, `.array(items:)`, `.object`, `.json`).
- **What it takes, said briefly**: `compactType(of:)` (`todo|doing|blocked|done`, `number ≥ 0`,
  `text (≤ 80)`, `JSON [text]`), the words of `canvas kinds` and of a query's vocabulary.
- **A literal read as the property's JSON**: `value(ofLiteral:quoted:for:)`, or `forItemOf:` for one
  item of a list. Unquoted `null` is the default (refused for a required property), a day alone is
  midnight UTC for a date-time, a number or true|false only unquoted, a list or an object as JSON.
  It refuses with `KindSchema.Refusal` (`.notAProperty`, `.notAChoice(choices:)`,
  `.notA(compactType:)`, `.required`, `.notFinite`, `.notJSON`), which holds no words: each command
  says it in its own, `draw` through Automation's `KindVocabulary`, a query through its resolution. A
  bound is never a refusal.

CanvasTests' KindSchemaTests pin every CanvasTesting kind's compact types and the properties that
hold a place, each refusal, and hand-written `$ref`s, read on a detached task; `draw`'s words stay
AutomationTests' and SkillTests'.

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

Typed props always have their schema's shape (the types, `required`, nothing else allowed), so what
a shape can break are the bounds its properties declare (`maxLength`, `minimum`, `pattern`,
`multipleOf`, ...), and a number that isn't finite, which a board writes as the string "nan" or
"inf". A message names the place by its schema's `title`, else by its path ("Title", "Items › item 3
› text"), and says what's wrong in the value's terms, so a message reads well where people see it.

The checker is 2020-12's validation vocabulary (`type`, `enum`, `const`, the bounds on numbers,
strings, arrays and objects, `required`, `dependentRequired`) and its applicators (`properties`,
`patternProperties`, `additionalProperties`, `propertyNames`, `prefixItems`, `items`, `contains`,
`allOf`, `anyOf`, `oneOf`, `not`, `if`/`then`/`else`, and `$ref` to any place in the same schema).
`format` is an annotation, as 2020-12 has it, and so is any keyword it doesn't know
(`x-canvas-owner`): neither is checked. It compares as JSON Schema does: strings code point for
code point (so "é" and "e\u{301}" differ, where Swift's `==` equates them), numbers by value. A
length is in code points too: a thumbs-up with a skin tone is two, so a message gives both counts
when they differ, without naming the standard ("Title counts as 82 characters (41 shown)"). A
pattern is ECMA-262's, run by ICU (`NSRegularExpression`) once what ICU reads differently is rewritten: `$`
ends the string (ICU's also matches before a final line break), `.` and `\s` are ECMA's, and `\d`,
`\w` and `\b` are ASCII. A pattern ICU can't read at all (a lookbehind of no fixed length) refuses
the plugin list, as one that's no regular expression does.

**Validation turns each violation into a warning.** The rule is Validation's own, for every kind
(`ValidationRules` on its line of the report), after the kind's own rules: the violation's message,
about the property it's in (`ValidationIssue.field`). So a bound is a guideline a shape can
break and still work: it's outlined orange, listed in its Issues tab, and dotted in the table of
contents, and it saves as it is. A rule that should refuse a shape is the kind's, as an error. The
engine checks a shape when it changes, as it does every rule, and reads every shape once, on the
first frame after a board opens: `./build.sh bench` holds that to 100 ms for 10,000 shapes. Where
a shape is is nothing its schema checks, so the rule [ignores moves](#a-horizontal-plugin): a
commit that only moves shapes (`ChangeSet.moved`) doesn't run it, and a shape checked again because
a shape its other rules looked up changed keeps what its schema said until it changes itself,
other than by moving. A drag that moves 10,000 shapes redoes the rules that read where shapes are,
not their schemas, and so does undoing or redoing it.

### Properties and metadata

A property is what a shape knows: a note's text, its title. It's in the kind's schema, for
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
| The shape it's bound to, or names | must be on the board | may be on any board of the file, or gone |
| Deleting it | lets go of it, in the deleting transaction | changes nothing: no delete looks for names, so the name stays, and names the shape again if it comes back with its id |
| Copying without it | lets go of it (an arrow's end stays where it's drawn) | keeps naming the original |
| Copying with it | is bound to its copy | names its copy, on whatever board of the copied tree it is |
| Cutting it, then pasting it (a move: [the clipboard](#the-clipboard)) | lets go of it at the cut, as a delete does; the paste doesn't bind it again | names it again once it's pasted, on whatever board, since it keeps its id |
| `canvas draw` with one that isn't there | refused (`invalid_value`: `the pin on line 1 is bound to a shape that isn't on this board`, or `… on another board of the file`) | made, with a warning if it's in no board of the file (or the script deletes it), or on a board the app can't show |

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
  A relation kept as names in an added property is an edge of [Topology](#sources)'s graph with
  one line, `registrar.edges(in: P.self, as: T.self)`.
- **Copying.** `record.remappingReferences(map, in:)` does both forms: first what the kind binds, as
  its `ShapeReferencing` says (nil lets a binding go), then every name, for `namingKinds` (nil keeps
  a name). A definition remaps what it binds and leaves names to the core. Clipboard's copy and
  paste go through it, so a note pasted with the shape it mentions mentions the copy, and one
  pasted alone mentions the original. `remappingReferences(bind, naming: name, in:)` passes the two
  forms through two maps, for a copy of a tree of boards: a binding is to a shape on its own board,
  copied with it or let go, while a name may be of a shape copied with it on any board of the tree
  (Clipboard's paste renames it to that copy) or of one anywhere else (kept). A paste of what a
  cut took maps each id the file doesn't use to itself (a move), in the same map, so a moved
  shape's names stay as they are, and so do the names of it anywhere else in the file.
- **Across boards.** Ids are unique across a file, so a name is of a shape wherever it is:
  `editor.file.record(id)` finds it, and a name of a shape on another board is no missing name.
  Only one that's in no board of the file is (`canvas draw` warns about those, and about names of shapes on boards the app can't show). Bindings
  stay on their board.
- **Deleting.** A delete lets go only of bindings: it asks only the kinds that bind, never a kind
  that only names, so deleting a shape writes nothing into the shapes that name it. On a kind that
  does both (`CitingTag`), a delete lets its binding go and keeps its names.
- **Bound, or named.** `record.boundShapes(in:)` is what a shape is bound to, what must be on its
  board, each once; the shapes it only names aren't in it. [`canvas draw`](#draw) checks it.

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
| `registrar.command(.delete)`, `.selectAll`, `.goBack`, `.openSelection`, `.zoomToSelection` and `.smartMagnify` (with their keys, through Keyboard) | Delete, and Edit › Delete (enabled while something's selected, a locked shape too, which refuses and shakes), deletes the selection; ⌘A, and Edit › Select All (enabled while the board has shapes), selects everything; ⌘[, and Go › Back (enabled while there's a step back), goes back to the previous selection; ⌘↓ (enabled while the only selected shape can be opened and nothing is being edited, as ⌘↓ is then the text's) opens it. Return and Enter (shortcuts of their own, which always take the key) run `.openSelection` too. ⇧2, and View › Zoom to Selection (enabled while something's selected), reveals the selection; a trackpad's smart zoom (a two-finger double-tap) reveals the shape under the pointer, and the next goes back. The arrow keys (shortcuts of their own, repeating) nudge the selection a world unit, ten with ⇧ (`nudgeSelection(by:)`: a `translate`, "Move", with no snapping), while `canNudge`. |
| `Tool.cancel` | Escape in Select, with nothing under way, deselects. |
| `Tool.ignoresPress` | The rest of a double-click whose first click, on a face, went somewhere (changed the selection or moved the camera) is ignored, so the camera goes on and nothing is placed or edited where it's brought. |
| `EditorService.documentDidChange`, `didPlace` | Drops shapes that are gone (or no longer selectable) from the selection and the hover; selects a shape just placed. |
| `EditorService.boardDidChange`, `editor.showBoard` | Another board shown: what was selected on the board left is a step back, and nothing is selected on arrival. |
| `EditorService.drawsSkeletonsDidChange` | The canvas started or stopped drawing [skeletons](#skeletons) under a pointer that may be still: in the select tool, with nothing under way, it looks again at what the pointer rests on, as a move there would, so a face's hovered target gives way to its shape. Buttons are looked for first, as on a move, so a button that comes or goes with the level (one that shows only in full, a blank label's shorter or longer reach) takes or gives up the hover without its plugin saying so. |
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
  puts the selection it leaves on a stack, with its board and the camera as it is at that moment
  (or, while it glides, `editor.cameraTarget`, where it's headed): a click, a row of the table of
  contents, Escape, a deletion. Going back takes the last one off, selects its shapes (less any that
  are gone) and animates the camera back over 200 ms, as data-canvas does. The detail panel's header
  has the back button, and Go › Back (⌘[) works whatever has the keyboard, but not mid-gesture.
  The stack holds 50 steps, skips a repeat of the step below, and going back skips a step that
  would change nothing: its shapes are all gone (unless it selected nothing, the board's list), or
  they're what's selected. `canGoBack` is true only when a step wouldn't be skipped, so after
  deleting the only shape selected there's no Back. It's per editor, so per window, and isn't
  saved. Showing another board is a step too, even with nothing selected: the board left, what
  was selected there and its camera (but not a file put in place, which no one took: a file opened
  on the board left open, or a revert that took the board shown). Nothing is selected on the board shown (going back isn't
  a step, nor is what the switch deselects), and the press, the hover, the hovered handle and
  canvas button are let go. Going back to a step on another board shows that board, selects what's
  left of the step's shapes there (even none: going there is the change), and puts the camera where
  it was, at once, not gliding from another board's; a step on a board that can't be shown any more
  (its owner deleted) is skipped, and `canGoBack` counts the steps on other boards. So ⌘[ after
  opening a shape's board comes back to the board it's on, with it selected, as Finder's ⌘[ comes
  back out of a folder. `showBoard(_:selecting:)` shows a board and selects there as one step (Back
  returns to the board left, not to the board shown with nothing selected); on the board shown, it
  only selects. Two differences from data-canvas: a press of the select tool and its drag
  are one step, so a marquee goes back to what was selected before the press, where data-canvas also
  keeps the moment the press on empty canvas deselected; and a step keeps the camera as the
  selection was left, not as it was made, so going back from a row's details returns to the list
  as it was before the zoom. There's no forward.
- `reveal(_:)` and `goTo(_:)` are the one way to bring shapes into view, for every plugin (the
  table of contents' rows, a mention followed out of text). `reveal` only moves the camera: it
  centers the shapes' bounds (`shapeContext.bounds(of:)`) in the part of the view the host leaves
  clear (`editor.unobscuredViewport`: below the path over a subboard's canvas), zoomed to fit with
  100 points of margin in all but no closer than 120%, over 200 ms, as data-canvas's table of
  contents does (tldraw's zoomToBounds). It's what selecting rows does, and Zoom to Selection
  (⇧2), only on the board shown, and does nothing before the view has a size. A trackpad's smart
  zoom (`smartMagnify()`, the `.smartMagnify` command, which the canvas runs on a two-finger
  double-tap) reveals the selectable shape under the pointer, and the next, while the camera is
  still where that one took it, eases it back, as Safari's and Preview's do. The canvas says where
  the gesture was first (host API `editor.pointerLocated(at:)`, which hovers nothing), since a
  gesture reaches a window that isn't key, where no move reached the canvas. `goTo` goes to shapes as following a link to them does: it ends editing, selects those that can
  be selected, and reveals them unless they're all in view already at a readable zoom. Selecting
  them is a step back when it changes the selection, so ⌘[ returns, camera and all; going to
  what's selected already, or to shapes none of which can be selected, leaves the selection as it
  is, takes no step, and only moves the camera. Readable is 70% or closer
  (`SelectionStyle.readableZoom`: a note's 16-point text reads at 11.2 points there, just over
  `NSFont.smallSystemFontSize`, the smallest macOS sets text to be read at), or closer for a kind
  whose text is set smaller than a note's, which says the zoom its shapes read at
  (`x.readableZoom(1)`, `registrar.readableZoom(K.self, _:)` for bridges; the `ReadableZoom`
  point, one per kind, each above zero and at most 120%, `ReadableZoom.maximum`, as close as `reveal`
  brings shapes; `editor.readableZoom(of:)`): 11-point text reads at 100%, so going to a shape of
  such a kind at 70% brings it closer (every shipped kind's text reads at 70%). Going to several,
  the closest of their kinds' counts. Or, for shapes too big
  to show whole at that, as close as fitting them would bring them, so going to a big shape that's
  all in view never zooms out to show what's shown. The camera is judged where it's headed
  (`cameraTarget`). The shapes may be anywhere in the file (a mention names a shape on any
  board): `goTo` goes to the board of the first of them on a board it can show (`canShow`), and to
  those of them on that board, leaving the rest; on another board it shows that board and selects
  them there as one step back (`showBoard(_:selecting:)`: ⌘[ returns to the board left, with its
  selection), then reveals them from the camera the board was left with, or its first visit's.
  `goTo` does nothing mid-gesture, or when none of the shapes is on a board it can show; without
  `SelectionPlugin` it ends editing, shows their board and reveals. data-canvas's navigateToShape
  always zooms.
- `goInto(_:)` follows a link into what it names (a mention of a subboard enters it): `goTo`, then
  `open` there if it opens (`canOpen`), as one step back, to the board and selection it was
  followed from, whatever boards it went through (the selection state runs both as one step,
  `asOneStep`, in which no selection change or board shown records a step of its own). A shape
  that doesn't open is only gone to; nothing mid-gesture, nor for a shape whose own board is shown
  (a subboard's mention followed from inside it), which is gone into already.
- `canOpen(_:)`, `open(_:)` and `openSelection()`: opening a shape, below.
- `hoveredHandle`, `brush` (the marquee), `isSelectable(_:)`, and the commands'
  `selectAll()`, `deleteSelection()` and `editSelection()` (editing alone, whatever opening would
  do).
- `selectionBounds`, the union of the selected shapes' geometry bounds, is kept from one read to
  the next while the selection, the board's shapes (`editor.revision`: every commit, undo and redo,
  another board shown) and the camera stay as they were, so the box around ⌘A's thousands is worked
  out again only after one of those changed, which saves each read (the canvas's frame, the
  minimap's, a hover's `isInSelectionBox`) a pass over the selection. The selected shapes' outlines
  still visit every one each frame: on the canvas a look at each one's kept extent, only those in
  view stroked ([drawing](#the-editor-the-document-and-drawing)); in the minimap each one's
  silhouette. Any commit works it out again, not only one naming a selected shape, since a shape's
  geometry may follow another's (a link's, its ends'), and so does any camera change, since a
  kind's geometry may read the camera: a pan still costs a pass over the selection once a frame,
  reading each shape's kept bounds (`ShapeContext.bounds(of:)`). Debug builds count the passes
  (`selectionBoundsWorkedOut`).

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
- `x.opens("Open") { shape, editor in … }` fills `ShapeOpening`: what opening one of the kind's
  shapes does, in place of editing it, as a board-owning kind shows its board
  (`editor.showBoard(BoardID(owner: shape.id))`); `registrar.opens(Kind.self, "Open") { … }` from a
  bridge. At most one per kind, plus one for every kind, which a kind's own overrides. A
  double-click on a shape, Return, Enter, ⌘↓ and `.openSelection` open it: `editor.open(id)` runs
  its kind's opener, else edits an `Editable` shape (`beginEditing`). `editor.canOpen(id)` says
  whether there's anything to do: a shape on the board shown whose kind has an opener or is
  `Editable`; a read-only shape of an `Editable` kind counts, since opening it is refused and the
  refusal shows (a locked note shakes), while an opener runs whatever the shape's lock (entering a
  board changes nothing). The title names it where it's offered (a menu item).
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
  threshold, but for a plain click on the only selected shape of an `Editable` kind (a note), which
  waits for the threshold and, released within it, edits the shape from the release, the caret
  where it's clicked (tldraw's); a read-only one is only selected, and so is one clicked on what's
  drawn for it outside it (a title's pill, which isn't its text), or by the click that brings its
  window forward (`Pointer.activatesWindow`, as Finder's click-to-rename ignores it). A
  double-click opens a shape, selected alone: its kind's opener, else editing an `Editable` one
  from where it's pressed (a note's word selected), if that's on the shape itself; on its pill, as
  with no press (the caret at the end). The release that follows a double-click that showed another board finds
  no press, and does nothing.
- A plain press on a [face](#faces-clickable-parts-of-a-shape) (a mention's pill in a note) is
  still the shape's, but waits for the threshold, even on a lone box, so that a release within it
  clicks the face; a double-click there is the face's too, in place of opening the shape.
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
  each commit, and with the [skeleton](#skeletons) level as it changes (Selection's
  `drawsSkeletonsDidChange`). One that comes or goes some other way (a chip fading out) calls
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
  the marquee and ⌘A (which go by geometry), the eraser and an arrow's end (it never binds through
  a pill) go by the shapes alone, and the hand tool pans over it.
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
- **None on a skeleton.** A shape drawn as a [skeleton](#skeletons), zoomed out
  (`editor.drawsSkeleton(of:)`), shows none of its content, so it has no faces: `at` is never asked
  for it, and a press, a click, a double-click and the pointer there are the shape's, as on a shape
  without faces. So a double-click edits an `Editable` one (from where it's pressed), which then draws
  in full, faces and all, and a read-only one's is a refused edit (a locked note shakes, and goes to
  no pill's target). The shape being edited draws in full, so it keeps its faces. As the level
  changes under a still pointer, Selection looks again at what it rests on
  (`drawsSkeletonsDidChange`, by the lookup a move uses), so a face's hovered target gives way to
  its shape zoomed out and takes the hover back zoomed in. A face pressed in full whose shape is a
  skeleton by the release (a pinch past 35% with the button held) isn't clicked: the release is the
  shape's, as a canvas button gone by the release isn't clicked (`PointingShapeSession.end` asks
  `drawsSkeleton(of:)` again).
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
registrar.shortcut(.return, "Open Selection") { $0.perform(.openSelection) }
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
| V, H, N, B, S, R, L, E | Switches to that tool | The tool's plugin; H by Keyboard, for the core's Hand |
| Space, held | A press pans as the Hand's does, whatever the tool, which stays the tool (`editor.isHandHeld`); let go (with ⌘ held too), or with the canvas losing the keyboard or a menu opening, it stops | Keyboard, for the core's held hand |
| ⎋ (and ⌘.) | Cancels: the drag under way, else the tool's own Escape, else back to Select (`editor.cancel()`) | Keyboard |
| ⌫ and ⌦ | Deletes the selection, as Edit › Delete does | Selection |
| ↩ (and ⌤), ⌘↓ | Opens the only selected shape: edits it, or its kind's own way (`ShapeOpening`); ↩ and ⌤ take the key even when there's nothing to open, ⌘↓ passes then | Selection |
| ⌘A | Selects everything, as Edit › Select All does | Selection |
| ⌘[ | Goes back to what was selected before, as Go › Back does (while there's somewhere to go) | Selection |
| ⌘↑ | Goes up to the board above, with the shape whose board it left selected, as Go › Enclosing Board does (off the root) | Boards |
| ⌘X, ⌘C, ⌘V | Cuts, copies and pastes shapes, as Edit › Cut, Copy and Paste do | Clipboard |
| ⌘Z, ⇧⌘Z | Undoes and redoes, as Edit › Undo and Redo do (held, again and again) | Keyboard, for the core's `.undo` and `.redo` |
| ⌘=, ⌘-, ⌘0, ⇧1 | Zooms in and out to the next stop (held, again and again), to 100%, and to fit the board, as View's items do | Keyboard, for the core's `.zoomIn`, `.zoomOut`, `.zoomToActualSize` and `.zoomToFit` |
| ⇧2 | Brings the selection into view, as View › Zoom to Selection does | Selection |
| ← → ↑ ↓ (⇧ too) | Nudges the selection a world unit, ten with ⇧, again and again while held, one undo step (while something's selected and nothing's under way or edited; a locked shape stays and shakes) | Selection |

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
- **A digit's chord is its key on the number row**, whatever the layout types with it: a key
  stroke says which number-row key it is (`KeyStroke.numberRowKey`, from the key code), and
  answers the digit with the modifiers held after the chords of what it typed. So ⇧1 (Zoom to
  Fit) is the key that types "!" with ⇧ on a US keyboard and "1" on a French one. The menu bar
  answers such an item's key the same way (View › Zoom to Fit, ⇧1), and never takes a key without
  ⌘, ⌃ or ⌥ from text, where it types; one held with fn (🌐) is AppKit's as ever, text or not (Edit
  › Emoji & Symbols, 🌐E, which answers only as a key equivalent).
- **`when`** lets a key pass: it goes on to the next chord it answers, or out of the canvas. **A
  held key** does its thing once; its repeats are the shortcut's all the same (so AppKit doesn't
  beep), and run it again only with `repeats: true`, for a key meant to be held, and only while
  the canvas has seen it go down: a key held down elsewhere (↓ in the table of contents, whose
  pick gives the canvas the keyboard) repeats on the canvas as nothing, until it's pressed again.
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
  key binding for it, or accessibility's cancel. The moves they send (an arrow key with nothing to
  nudge, `moveLeft:`; Page Down, `scrollPageDown:`) and what they'd type (`insertText:`) stop at
  the canvas, which does nothing with them, so a stray key doesn't beep. The canvas answers no other action, which goes on
  up the responder chain.
- **Tooltips.** `registry.help(for: tool)` is a tool's label and its key, "Note (N)", and
  `registry.help("Enclosing Board", forCommand: .enclosingBoard)` a button's that runs a command,
  "Enclosing Board (⌘↑)" (the list's way up, through Composition). The toolbar (CanvasUI) can't see
  Keyboard, so the app hands it `ShippedPlugins.help(for:in:)`.
- **The core's part** is one hook, like the secondary click's: at most one plugin claims key strokes
  (`registrar.keyStrokes { editor, stroke in ... }`, returning whether it took the key). `CanvasView`
  hands every key it gets to the editor (`editor.keyDown`, host API), as a `KeyStroke`: its
  characters as the keyboard's layout types them with no modifier but ⇧, the modifiers held, and
  whether it's a repeat. Without a claim, no key does anything on the canvas. Keyboard gathers each
  editor's shortcuts by chord once, in a service (`KeyboardState`), since the registry is frozen.
  The plugin that claims key strokes claims their releases too (`registrar.keyReleases { editor,
  stroke in ... }`): `CanvasView.keyUp` hands the editor each key let go (`editor.keyUp`), and
  `editor.keysReleased()` every key at once, as the canvas loses the keyboard, its window stops
  being key or a menu begins tracking (`NSMenu.didBeginTrackingNotification`: its loop takes the
  keys), where no release would reach it; a key let go with ⌘ held, which NSApplication never hands
  the key window, reaches the canvas that has the keyboard through a local event monitor. Keyboard
  runs a shortcut held down
  (`registrar.shortcut(chord, "Title", whileHeld:released:)`) once as it goes down, takes its
  repeats, and runs its release as it comes up: Space's, which holds the core's hand
  (`editor.isHandHeld`: a press pans as the Hand's does, whatever the tool, which stays the tool,
  since `setTool` would reset an arrow's targeting; the open hand, the closed one while it pans, and
  no hover meanwhile; held during another press, a drag, it waits for that one: the drag keeps its
  cursor, and at its release the tool hears the pointer leave and the open hand shows). The middle
  button pans the same way, through its own host entry point (`editor.panPointerDown`, from
  `CanvasView.otherMouseDown`), editing going on; released over a view the canvas hosts (the note
  being edited), the pointer leaves the canvas there, as a left press's release does. One press at a
  time: a left press during the middle button's pan ends the pan and is the press from then on.

## The detail panel

The detail panel is the inspector beside the canvas, after Keynote's: it shows the selected shape
and edits its properties. It's a horizontal ([`Sources/DetailPanel`](../Sources/DetailPanel)) like
any other. It declares two extension points, kinds and other plugins contribute to them, and the
core has never heard of it.

### Anatomy and conventions

```
┌─ inspector column: 248 to 340 pt, 260 ideal ────────┐
│ ‹ {}  Customer                                      │ header: back, symbol, title (here a
│       2 fields                                      │   field: the card is renamed there)
│ ⟦ Schema ⟧  Issues                                  │ tab strip, hidden with one tab
├─────────────────────────────────────────────────────┤
│ ⌄ JSON                                              │ a titled section collapses; its rows
│   ┌─────────────────────────────────────────────┐   │   are stock SwiftUI and the panel's
│   │ { "title": "Customer",                      │   │   primitives, here code, monospaced,
│   │   "required": ["email"],                    │   │   as tall as its lines
│   │   "properties": { "name": {}, "phone": {} } │   │
│   │ }                                           │   │
│   └─────────────────────────────────────────────┘   │
│   ⚠ “email” is required, but isn’t a property.      │ a status line of the section's own
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
| Section chrome: the header, chevron, insets, dividers, collapsing, and remembered collapse | Section titles, ids and order |
| Scrolling, the footer, and the empty states | The rows in a section, and status lines: the footer's, or a tab's (the Issues tab above, while the card has any) |
| Fonts, control size, the label column and checkbox toggles, all through the environment | |
| Focus: what gives the keyboard back to the canvas | |

With nothing selected the panel shows its overview, a view the host may give it (the app's is [the
table of contents](#the-table-of-contents)), else "No Selection". With several, it shows "N Shapes"
over the kinds selected, then the overview (details are per shape: editing several at once isn't
built). A shape with no sections to show (an arrow, a rectangle, a note without issues) gets its
header, then "No Options". Without `DetailPanelPlugin` installed, the panel says "No Details". A
read-only shape (a [locked](#locking) one) shows its whole panel, but nothing in it edits the shape:
the panel disables its sections' content, and its header (a title field), and leaves going back, the
tabs and collapsing as they were. A section whose controls change nothing of the shape says so,
`DetailSection(…) { … }.enabledWhileReadOnly()`, and keeps them working (Boards' Open: a locked
shape's board is entered like any other's); whatever they write is refused there all the same. It
asks the registry (`registry.isReadOnly(record)`), not the editor, so the panel doesn't read the
document.

Sections are stock SwiftUI plus a few primitives, and get the look by following these conventions:

- **Rows.** A labeled control is `LabeledContent("Status") { control }`; the panel lines every label
  up in one 72 pt column and hides the control's own label (its placeholder stays). A read-only
  value is `LabeledContent("Fields", value: ...)`. A toggle stands alone, drawn as a checkbox
  with its label after it; in a row, it's a bare box, beside what it governs (a due date's
  checkbox, beside the date).
- **Primitives.** A number is a `DetailNumberField`, and a pair of them (Width and Height) goes in
  `DetailFields`. Multiline text is a `DetailTextArea` (with a `placeholder:` shown while it's
  empty, and an `onCommit:` for text that's acted on once it's done: then Return commits, ⇧↩ is a
  new line, and the keyboard leaving commits too, a turn later if the text view left its window
  with the keyboard, so capture a service in `onCommit` weakly: the board may have gone), code a
  `DetailCodeEditor` (monospaced, typed exactly as keyed: smart quotes and dashes, text
  replacement, autocorrect, spelling, automatic completion, inline predictions, math results and
  Writing Tools off; lines never wrap, so a line's indentation says where it is and line N of an error is
  the Nth on screen, and a long one scrolls sideways; as tall as its lines, from
  `DetailStyle.codeEditorHeight` (a text area's height, so a short text sits in a short box with
  what's said about it close under it) to what the panel shows, less room for its section's title; Tab
  two spaces, Return a new line as indented as the last, one step more after `{` or `[`; ⌘↩ and the
  keyboard leaving call its `onCommit`; `isEditable: false` makes it read-only; `coloring:` colors
  its runs and `completions:` completes it, below), a list a
  `DetailList` (empty, it says No Items), a color `DetailSwatches` (named presets, the chosen one
  marked, then the color well; it spans the row, so it goes in a section of its own, not in a
  `LabeledContent`). `.detailUpdating(isUpdating)` marks a text box something else is writing just
  now (a model): read-only, and so dimmed; nothing is drawn over its text. What's writing it says
  so in words where the person is: a status line of a section's own, a `DetailStatusLine`, drawn
  as the footer's (only its symbol takes the tone; its text can be selected and copied, and a line
  whose selected text has the keyboard as it goes hands the keyboard back to the canvas, as a
  field that goes does), with a spinner in the symbol's place, as wide,
  while `isBusy`, and link buttons under it
  (`DetailStatusAction("Retry") { … }`). Put it where it can't be collapsed away from the person. Text that isn't a string (mentions
  of shapes) goes in a box as a text area's, over a text view of the plugin's own
  ([`DetailTextBox`](#text-of-a-plugins-own-detailtextbox)): Mentions' `MentionTextArea` is one.
  `DetailNumberText` formats and parses numbers with units ("240 pt"), in the user's locale ("2,5 h" in German), as the number field does. A
  `DetailCommandButton("Open", systemImage: "arrow.down.right.square", command: .openSelection)`
  runs a command a plugin registered (`editor.perform`), dimmed while it can't run
  (`editor.canPerform`): the panel's counterpart of a menu item, borderless like the panel's other
  buttons. It finds the editor in the environment the panel sets, so a section still never sees it.
- **Code's colors and completions.** A `DetailCodeEditor`'s language is its plugin's; the panel
  colors it and completes it. `coloring: { text in … }` names the text's runs (`DetailCodeSpan`:
  a name, a string, a number, a keyword, or what doesn't belong, red and underlined), asked for
  the whole text at every keystroke, so a scan, not a parse. `completions: { text, caret in … }`
  (a `DetailCodeCompleting`, the caret in UTF-16) says what can be typed at the caret, or nil: a
  `DetailCodeCompletions`, the `range` a pick replaces (it holds the caret), what's typed so far
  (`query`), and every candidate, as offered and unfiltered, each a `DetailCodeCompletion` (its
  `label`, a `detail`, the `insert` that replaces the range, the `selection` within it a pick
  leaves, the caret or what's to be typed over, `reopens` where that has completions of its own,
  and `isRelevant`). ⌃Space opens the list (so does AppKit's `complete:`, ⌥⎋ and F5, since macOS
  may keep ⌃Space for switching input sources) while the text can be written, where something's
  offered: nothing opens elsewhere, and nothing beeps. It's the app's one caret list (Mentions' `@`
  picker's, [below](#text-of-a-plugins-own-detailtextbox)), under what's typed, each row the label
  in the code's font, what's typed matched in its semibold, then the detail, which takes what the label leaves (cut short with "…" past that),
  VoiceOver saying both; no header, no footer. While it's open ↑ ↓ (⌃P ⌃N) and Page Up and Down
  move through it, Return, Enter and Tab pick, Escape, ⌘., ⌃Space, ⌥⎋ and F5 close it (the panel
  stays; a second Escape leaves it), ⌘↩ closes it and commits, as ever (the list's key is Return,
  never ⌘↩), and every other key is the text's. After each keystroke and
  move of the caret it asks again and ranks what's offered by what's typed, with
  `CaretListMatcher`'s tiers (nothing typed: as offered; else the best tier first, then what
  `isRelevant`, then as offered; what doesn't match is left out), and closes once nothing's left,
  the caret leaves the place it opened for (the range starts elsewhere), the text is shown from
  outside or can't be written (`detailUpdating`, a locked shape), the keyboard or the window goes,
  the window stops being key, or what's typed scrolls out of view. A pick replaces the range with
  its `insert`, one step of the text's undo that the box writes as typing (so it joins the field's
  run of writes, and in a board's window a click in the list, a child window, doesn't end it), and
  one that `reopens` opens the list again at once. `onCompleting: { isOpen in … }` hears the list
  open and close (a pick that opens it again, not at all: it's still open), for what waits on the
  person's choosing: text a pick leaves waiting for a value may already be whole (`"type": ""` is
  JSON), so the schema card's sync holds its idle wait meanwhile. Without `completions`, F5 does
  nothing and ⌥⎋ leaves the panel as Escape does: code gets no dictionary words. The schema card's JSON is the
  shipped one ([Schema cards](#schema-cards)).
- **Sections.** A tab's first section may be untitled; use it for the main properties. Every
  titled section collapses. Titles are one or two nouns in Title Case.
- **No styling of your own.** No fonts, sizes, padding or backgrounds.
- **Writes** go only through the section's `ShapeBinding`. Sections never see the editor; one that
  shows a plugin's own state about its shape reads that plugin's service, `$x.service(S.self)` (the
  schema card's sync), from a view of its own, so observing it redraws only that view.

### Tabs are types; any plugin adds one

A tab is a type conforming to `DetailTab`. Any module may declare one, and there's no registration
call: a tab shows for a shape when a shown section that applies to the shape names it.

```swift
public enum BoardTab {}
extension BoardTab: DetailTab {
    public static var title: String { "Board" }
    public static var order: Int { 50 }
}
```

Being a type, a tab can't be misspelled, and sharing one means importing the module that declares
it. Tabs sort by `order`, then by first appearance, in these bands:

| Order | Tabs |
|---|---|
| 0 (the default) | A kind's own tabs (Schema) |
| 50 | Feature tabs a horizontal brings to the kinds that opt into it (Boards' Board) |
| 100 | `StyleTab`: appearance, shared by every kind |
| 300 | A tab of the shape's state that comes and goes with it (ValidationDetails' `IssuesTab`, Mentions' `MentionsTab`): last, so the others keep their order |

Use the shared `StyleTab` rather than a near-duplicate. Two tab types with one title
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
and its content. `when` runs on every render, so keep it cheap. The panel contributes no sections
of its own ([`DetailPanelPlugin`](../Sources/DetailPanel/DetailPanelPlugin.swift) registers only
its state, `registrar.service { DetailPanelState(editor: $0) }`): every section is some plugin's.
Sections for every box, in a Frame tab of their own (DetailPanelTests' `FramesPlugin`):

```swift
registrar.detailsForEveryBox {
    DetailSection("Size", in: FrameTab.self) { $frame in
        DetailFields {
            DetailNumberField("Width", value: $frame.size.width, unit: "pt", in: 1...100_000)
            DetailNumberField("Height", value: $frame.size.height, unit: "pt", in: 1...100_000)
        }
    }
    DetailSection("Position", in: FrameTab.self) { $frame in ... }
}
```

`when` reads only the value. A section of the shape's state that a service knows (whether other
shapes mention it) says when it shows with `shownWhile`, over the record and a `DetailContext`, as
Mentions' Mentioned In does:

```swift
DetailSection(in: MentionsTab.self, id: "mentioned-in") { $x in
    MentionedInList(target: $x.shapeID, mentions: $x.service(MentionState.self))   // the shape, whatever the value
}
    .shownWhile { shape, context in context.service(MentionState.self)?.isMentioned(shape.id) == true }
    .enabledWhileReadOnly()
```

It's asked on every commit, whatever the commit changed (a drag of another shape), as status
lines are, so it must cost O(1): read a service's cached state. Only the sections that have one
are asked (found once per kind), so a kind without any costs nothing. A section it hides takes its
tab with it when the tab has nothing else to show, and the shape's panel is built again only when
what it hides changes; a view in the section that shows more of that state observes it itself,
since the section is built again only when its shape changes.

How it resolves, per shape:

| What | Order |
|---|---|
| Sections in a tab | The kind's own (from its vertical, a horizontal it opts into, or a bridge), in plugin order and builder order; then every kind's (every-box sections, and those over an added property on every shape that has it), in plugin order. |
| Tabs | By `order`, then first appearance over the same sequence, then status lines'. A tab with no shown section (by `when` and `shownWhile`) and no status line is dropped. |
| Status lines, the footer's and each tab's | The kind's, then every kind's, each in plugin order. |
| Header | The kind's own; else the kind's label and symbol (`registry.label(of:)`: what the kind declares, else its placing tool's, else its id). A header without a symbol takes the kind's. |

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
  panel lays them out. A kind without a header of its own gets one with its label
  (`registry.label(of:)`).
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
sub.details(header: { $sub in TitleHeader($sub, placeholder: "Untitled Subboard", systemImage: "rectangle.stack") }) {}
```

It's a `DetailHeaderLabel` whose title is a `DetailHeaderField`. Each keystroke renames the shape
(one transaction), so its pill and its row in the table of contents follow as you type. Given the
shape, it renames the title Titles keeps (`$note[TitleProperty.self]`, which the kind must opt
into with `note.title()`: a debug build stops at one that doesn't): clearing the field, or leaving
only spaces in it, sets nil, since Titles keeps no blank title; anything else is kept as typed, and
one past 80 characters is kept, and warned about. A title derived from what the kind keeps is
renamed where it comes from, given that binding instead: a `String?`, or a `String` blank while
untitled (`TitleHeader($card.text)`). While there's no title it shows its placeholder,
dimmed: the kind's name ("Note"), unless the kind gives one ("Untitled Subboard").
`isEnabled: false` dims it while something else writes the title (a schema card's model);
`isRenamable: false` shows it as text, at full strength, while it can't be written at all (a schema
card's text that isn't a JSON object). A derived title that can't ever be renamed (a kind's that
nothing names) isn't; a kind with one keeps a `DetailHeader`, if it has a header at all.

Opting into titles doesn't place it: the header is the kind's, which may want its own subtitle,
placeholder or symbol, or no rename in the panel at all.

### A horizontal's feature tab: Boards

The pattern the panel is built for: a horizontal exposes a way for individual shapes to opt into a
feature, and the feature shows up as a tab in the panel. Opting in is one line on the kind, and the
tab comes with it, on exactly the kinds that opt in.

[Boards](#boards) makes the shapes of any kind that owns boards open onto them. It owns its point
(`BoardKinds`: what a kind's boards are called while their owners have no title, and their
symbol), the tab (`BoardTab`), the menu group (`BoardsMenuGroup`), and going in and out of boards;
its sugar contributes to its own point, to Selection's opening, and to the panel's and the menu's,
from the same `ShapeRegistrar`, fully typed ([OpensBoard.swift](../Sources/Boards/OpensBoard.swift)):

```swift
/// The extension point: which kinds' shapes open onto their boards, and what a board is called
/// before its owner is named. At most one per kind.
public enum BoardKinds {}
extension BoardKinds: KeyedExtensionPoint {
    public typealias Contribution = BoardKind                  // a placeholder and a symbol
    public static var owner: PluginID { .boards }
    public static func uniqueKeys(of _: BoardKind, for target: ShapeTarget) -> [AnyHashable] { [target] }
}

extension ShapeRegistrar where Definition: BoardOwning {
    /// Opening this kind's shapes shows their boards: a double-click, Return, ⌘↓, Open first in
    /// their context menu, and an Open button in their panel's Board tab.
    public mutating func opensBoard(placeholder: String, systemImage: String) {
        contribute(BoardKind(placeholder: placeholder, systemImage: systemImage), to: BoardKinds.self)
        opens("Open") { shape, editor in editor.showBoard(BoardID(owner: shape.id)) }
        contextMenu {
            MenuItem("Open", in: BoardsMenuGroup.self) { ids, editor in
                if let first = ids.first { editor.open(first) }
            }
        }
        details {
            DetailSection(in: BoardTab.self) { _ in
                DetailCommandButton("Open", systemImage: "arrow.down.right.square", command: .openSelection)
            }
            .enabledWhileReadOnly()                                // a locked shape is opened all the same
        }
    }
}
```

- **Opting in.** Subboards writes `sub.opensBoard(placeholder: "Untitled Subboard", systemImage:
  "rectangle.stack")`, and a bridge `registrar.opensBoard(P.self, placeholder:systemImage:)`. The
  kind declares nothing. Its definition must be `BoardOwning`, which the sugar's `where` holds it
  to, and `BoardKinds.check` holds a bridge's to, since its form can't say so in its types.
- **The graph.** Subboards imports Boards and never ContextMenus or Selection, yet its shapes open
  and have Open in their menu. The requirement shows up at startup instead: a list with Subboards
  but without `BoardsPlugin`, `SelectionPlugin`, `ContextMenusPlugin` or `DetailPanelPlugin` is
  `ownerNotInstalled`, naming the missing one.
- **The tab runs a command.** Its one section is a `DetailCommandButton` for `.openSelection`, what
  ⌘↓ and Go › Open Selection run, so the panel, the menu and the keys open alike, and it dims when they
  can't. Opening changes nothing of the shape, so the section is `enabledWhileReadOnly()`.

Another feature in this pattern has the same parts: a keyed point for whatever it needs per kind
(Boards' placeholder and symbol); a tab type at order 50 (and a menu group, if it has actions);
when its shapes hold something, an added property declared by the horizontal, with sections and
items over its value (`details(of:)`, `contextMenu(of:)`; [added properties](#added-properties));
sugar that contributes them all from the kind's registrar; and whatever consumes it (a lookup on
`Registry`, an adornment).

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
severity's symbol, red or orange, then its message. The tab is at order 300, after every
other, so the other tabs keep their order as it comes and goes, though not their width: the
strip shares its width among its tabs, and a kind with one tab (a subboard's Board) gains a
strip with it. Any tab whose lines warn or err draws its worst tone's symbol before its title in
the strip (`layout.alert(in:)`: the triangle or the octagon, in its color; no count), so from
another tab it reads as a tab of problems, as the canvas's outline does. The tab is remembered per kind, as any is: once someone chooses Issues, the next
shape of that kind with issues opens on it, and one without opens on its first tab. A tab's lines
lead it, above any sections another plugin puts there. A status contributor reads services through
`DetailContext`, read-only. Status lines are re-read on every document change, so read a cached
service, as this one reads validation's engine. Without Validation installed there's no engine,
no lines, and no tab. So a note whose title runs past 80 characters has an Issues tab that says
"Title is 90 characters long, and should be at most 80.", and StickyNotes didn't change.

### The full showcase: schema cards

[Schemas](#schema-cards) is a vertical whose cards' panel is where their schema is written (what
it holds in words is typed on the card itself). Press S to place one. `schemaPanel()` (in
[SchemaPanel.swift](../Sources/Schemas/SchemaPanel.swift)) is one `details` call:

```swift
details(header: { $card in schemaHeader($card) }) {
    DetailSection("JSON", in: SchemaTab.self) { $card in SchemaCode(card: $card) }
}
```

The section is a view of its own, declaring `@ShapeBinding var card: SchemaCard`, so it can show
what the plugin's service keeps about the card (`$card.service(SchemaSync.self)`, the sync's
status) and redraw alone when that changes:

```swift
struct SchemaCode: View {
    @ShapeBinding var card: SchemaCard

    var body: some View {
        let sync = $card.service(SchemaSync.self), id = $card.shape.id
        let status = sync?.status(of: id) ?? .idle
        DetailCodeEditor($card.schema, coloring: ..., completions: ..., onCommit: { [weak sync] in sync?.commit(id) })
            .detailUpdating(status == .updating(.schema))
        // the card's Validation issues, a DetailStatusLine each
        SchemaSyncLine(status: status, sync: sync, id: id)
    }
}
```

The JSON is a `DetailCodeEditor` over `$card.schema`, its writes one run of undo, with the card's
Validation issues under it, a `DetailStatusLine` each, and the sync's status. The header renames
the schema's `"title"` alone (`setTitle`), dimmed while the model writes the schema
(`isEnabled: false`), and shown as text while the text isn't a JSON object (`isRenamable: false`).

Three plugins fill one card's panel:

| Part | Holds | From |
|---|---|---|
| Header | the name, renamed in place ("Untitled", dimmed, while there's none), over how many fields it has: "2 fields" | Schemas, with Titles' `TitleHeader` |
| Schema (0) | the JSON, its issues and the sync's status under it | Schemas |
| Issues (300) | the card's issues, worst first ("A schema must be a JSON object."), while it has any | ValidationDetails |

### Reading and writing: `ShapeBinding`

A section's content closure gets a `ShapeBinding`. Take it as a `$` parameter, as with
`ForEach($items) { $item in }`:

- **`card.schema` reads the snapshot** the panel drew with. Nothing in a section reads
  `editor.document`, so a section isn't rebuilt when other shapes change.
- **`$card.schema` is a `Binding`.** Each set writes that one key path into the *live* shape, in its
  own `editor.transact`. A move made after the snapshot survives a rename, two writes in one action
  both land, and setting the value the shape already has commits nothing. After a write, the
  binding reads what it made of the shape, before the panel draws again, as SwiftUI expects of a
  binding: a text field that takes Return (or Escape) straight after a keystroke would otherwise
  put the text from before back.
- **Writes go to the shape the binding was made for**, never to whatever is selected by the time
  they happen. A write to a shape that's gone does nothing.
- **Read-modify-write goes in `update`**: `$badges.update { $0.append("New") }` (DetailPanelTests'
  `Badges`, a list of strings) applies the change to the live value, in one transaction.
- **Bind the narrowest key path.** A collection's binding (`$badges[dynamicMember: \.self]`, and the
  row bindings `ForEach` derives from it) writes the whole collection, rebuilt from what the binding read (the
  snapshot, or its last write). Use `update` for list operations.
- **`$note.shape` is the whole shape** the snapshot came from, a `ShapeRecord<StickyNote>`: its
  props and its [added properties](#added-properties)' values, for what a section or a header shows
  from both (`$note.shape[TitleProperty.self]`, `$card.shape.id`). It only reads; writes go
  through the binding.
- **`$note[TitleProperty.self]` binds an added property** of the shape, a `Binding<String?>`: nil
  while the shape has none, each write one transaction on the live shape, nil removing it (for a
  property whose default is nil). It reads back its last write, as the key paths' bindings do.
  `TitleHeader($note)` renames through it.
- **Three kinds of binding, three write paths.** A kind's own sections get its props, typed, only
  from contributing for the kind: from its own plugin, a horizontal it opts into, or a bridge.
  Every-box sections get a `ShapeBinding<CGRect>`, the frame, whatever the kind. Sections over an
  added property get its value (`ShapeBinding<P.Value>`), on the shapes that have one. Any
  of them binds an added property of its shape by its type (`$x[P.self]`), through the whole
  record: nil, and writes dropped, on a kind that doesn't opt into it (`$x.holds(P.self)` says
  whether it does). The added properties' bindings one `$x` makes read back the last write through
  any of them, until the panel redraws.
- **Other forms.** A plain parameter works too (`badges.wrappedValue` is the snapshot), and a
  larger section can be a View declaring `@ShapeBinding var card: SchemaCard`, passed `$card` (the
  schema card's `SchemaCode`, above).
- **Undo steps.** A write is named for its section, "Change" and the section's title ("Undo Change
  JSON"); in the header, or a section without a title, "Change" and the kind's name ("Undo
  Change Schema", its label). Writes to one field of one shape, one after
  another, are one step, however many keystrokes (a field typed into, a slider or a color
  dragged): a run under the key `[shape, key path]` (for the frame's too), or `[shape, property
  key]` for an added property's binding and `$x[P.self]`, until anything else happens: a write to
  another field, any other change, an action, or the host sealing the run as the user clicks or
  types somewhere else (`editor.undoHistory.seal()`, which the board's window calls). Each `update`
  is a step of its own. A field whose writes go through a method of the
  value, because they change more than the field says, runs as the field does with
  `update(\.field) { ... }`: the schema card's header's rename is `update(\.schema) { $0.setTitle(name) }`
  (which rewrites one member of the schema's text), so what's typed is one step, as
  `$card.schema`'s is.

Tests and tools reach the same bindings with `editor.shapeBinding(id, as: SchemaCard.self)`,
`editor.frameBinding(id)` and `editor.propertyBinding(id, TitleProperty.self)`.

Two compiler rules come with this:

- **Keep the sugar's closure types unannotated.** Annotated `@MainActor`, Swift 6.3 compiles a
  `$`-parameter body as nonisolated, and every view initializer in it fails.
- **Never name `Transaction` in a file that imports SwiftUI.** SwiftUI has its own `Transaction`,
  and its `Canvas` view shadows the core module, so `Canvas.Transaction` doesn't resolve either.
  Let closure inference type `$0`.

When each control commits:

| Control | Commits |
|---|---|
| Text fields, `DetailTextArea`, `DetailCodeEditor`, a `DetailTextBox` (`MentionTextArea`), `DetailHeaderField` | On every keystroke, so the canvas follows as you type. With `onCommit:`, a text area or a box also says when it's done (Return, ⌘↩, the keyboard leaving), and a code editor too (⌘↩, the keyboard leaving) |
| Pickers, toggles, steppers, dates, swatches, the color well, list add, remove, move and edit | On change |
| `DetailNumberField` | A draft: on Return, Tab, leaving the field, or the field going away, in one transaction, clamped to its range. Escape drops the draft. Stepping writes at once. A draft lands on its own shape even if the selection moves first. |

### Text of a plugin's own: `DetailTextBox`

`DetailTextArea` and `DetailCodeEditor` edit a string. Text a plugin keeps in a form of its own
(mention text, which holds pills) edits in a `DetailTextBox`: the same box, laid out, bordered and
scrolling as a text area is, over a text view the plugin makes. Mentions' `MentionTextArea` is one
([In the panel](#in-the-panel-mentiontextarea)):

```swift
public var body: some View {
    let text = shape.wrappedValue[keyPath: field]
    DetailTextBox(shape[dynamicMember: field], height: height, placeholder: placeholder, onCommit: onCommit) {
        MentionTextView<Scope>(frame: .zero, text: text, style: MentionStyle.panelText,
                               owner: shape.shapeID, mentions: shape.service(MentionState.self))
    }
}
```

- **The view** is a subclass of `DetailTextView` (an open `NSTextView`) that adopts
  `DetailTextContent`: its `value`, of a type of its own (`ScopedMentionText`), and `show(_:)`.
  Adopt it on the subclass: `DetailTextView` adopting it would fix every subclass's `Value`. The
  panel's own boxes (`DetailCodeEditor`, and a `DetailTextArea` with `onCommit:`) are the same,
  over an internal `PlainTextView` whose value is a string, on TextKit 1 as they always were; a
  `DetailTextArea` without `onCommit:` is SwiftUI's `TextEditor`.
- **What it adds does nothing until it's set**, so the same class outside the panel is a plain
  text view (a note's editor on the canvas is a `MentionTextView` with only `onCommit` set, which
  ends editing, and `commitsOnLeaving` off):
  `onCommit` (⌘↩, the keyboard leaving, and the view leaving its window with the keyboard, a turn
  later; without it ⌘↩ goes on as any key does), `commitsOnReturn` (with `onCommit`, Return
  commits and ⇧↩ is a new line), `commitsOnLeaving` (on unless set: off, only ⌘↩ commits, for
  text a host ends itself: a note's and a schema card's on the canvas, which end with editing, the
  card's too as the keyboard goes to a view outside the canvas), `onExit` (Escape: the panel's hand-back to
  the canvas) and `placeholder`. The box sets them from its arguments.
- **The binding.** The box writes `value` to the binding after every change the view reports, so a
  field's run of writes is one undo step, as a text area's is. It calls `show(_:)` only when the
  binding changed from outside (an undo of the board, another plugin's write), never for a change
  it wrote, so a keystroke typed before the panel draws again is never lost. `show` changes the
  storage alone (the caret stays where it was, as far as the new text reaches) and never calls
  `didChangeText`, since the box may call it while the board applies an undo step, when nothing
  may commit; then the box drops what typing registered with its undo. In a board's window, Edit
  › Undo is the text's own while it has the keyboard ([Undo](#undo)).
- **Keys the view holds.** A view that shows a list at its caret (below: Mentions' `@` picker, a
  code editor's completions) keeps its window and says so, `override var caretListWindow:
  CaretListWindow? { pickerWindow }`, and `DetailTextView` does the rest, for every such list
  alike. While one's open, the view `holdsKeys`: the list's commands (`CaretList.perform`) go to it
  before the delegate's turn, a pick and a close through the window's `pickHighlighted()` and
  `closeList()`, which run its owner's; Return and Escape are never `onCommit`'s or `onExit`'s, and
  ⌘↩, where the text commits, closes the list and commits, as it does with none.
  The panel's root hears Escape before the view with the keyboard does, and leaves the panel, so
  it lets Escape through only to a `DetailTextView` holding keys: with the list open, Escape closes
  it, and a second leaves the panel. ⌘. comes as no key: the window sends `cancelOperation:` up
  the responder chain from the view, which closes an open list; with none, it goes on up as though
  the view didn't answer it, so the panel's root hears it (`onExitCommand`) and leaves the panel as
  for Escape. The keyboard leaving the view, the view leaving its window and its being made
  read-only close the list too. What's left to the subclass is when a list opens, what it lists,
  and what a pick puts in. A subclass that holds keys for something else says so, `override var
  holdsKeys`. A view that `offersCompletions` (a code editor with completions, while it can be
  written) has ⌥⎋ for its own too, list or not: the panel lets Escape with ⌥ through to it, for
  AppKit's `complete:`, and leaves on it anywhere else. Tests read where a list is placed and what
  it lists through `caretListWindow`.
- **A list at the caret.** What such a view shows over its text is the app's one caret list,
  DetailPanel's, whatever the text (Mentions' `@` picker and a code editor's completions are
  built on it). Its model, `CaretList`, is headless: rows (`CaretListRow`: a header, an
  item, or the one row an empty list shows), the highlight (the first item as rows are set; ↑ ↓
  wrap, a page of `rowsShown` stops at the ends), and `perform(_:)`, which says what a text view
  command does to it (↑ ↓ ⌃P ⌃N and Page Up and Down move, Return and Tab pick, but aren't taken
  with nothing highlighted, Escape, ⌥⎋ and F5 close; every other command is the text's). An item
  (`CaretListItem`) is what its row shows, one line: a title with its matched characters in
  semibold (in the item's `font`, if it has one), a symbol in its tint before it, a
  `trailingSymbol` after it (a read-only shape's lock), a `detail` at the trailing end, and what
  VoiceOver says, the title and detail unless it says otherwise. Its size is its owner's
  (`CaretListMetrics`: width, row height, rows shown, the offset below the anchor), its look
  `DetailStyle`'s. `CaretListWindow(list, accessibilityLabel:over:anchor:pick:close:post:)` shows
  it: a borderless child of the text's window that never takes the keyboard (not deferred, so a
  click's events name it, shown or not; a board's window, which ends a run of panel writes on a
  click in another window, leaves clicks in its children alone), under the anchor
  range's `firstRect` (its rows' text under the anchor's start; above the line where there's no
  room below; on screen), following every view the text is in as it moves or scales, and asking
  its owner to `close` once the anchor leaves the text's visible rect or the window stops being
  key; VoiceOver hears it change and go through `post`, which an owner may route (Mentions counts
  what its picker says). The owner decides the rest: when it opens and closes, what the query is,
  what it lists (`setRows`), and what a pick inserts (`pick` gets the row's index); it calls
  `listDidChange()` after each change and `dismiss()` as it closes. Both lists rank typed text
  alike, with `CaretListMatcher` (Mentions' tiers, `CaretListRanking`): `rank` is the two passes
  every list makes, every tier but the typo's over the labels it gives (nil for one it leaves
  out), then the typo's over the rest only when fewer than 8 matched, which Mentions' catalog
  makes over its keys and `matches(_:in:)` over a list of labels.
- **Enabled or dimmed.** A read-only shape, or `detailUpdating` (any `disabled` around the box),
  makes the view read-only, and the box asks `showEnabled(_:)` on every update: by default the
  text's color, the label's or the secondary label's. A view that colors its text itself says how
  (`MentionTextView` fades whole, text and pills, by its `alphaValue`). The box is dimmed by its
  view alone, and SwiftUI sees it enabled, since SwiftUI takes every click over a disabled
  representable: so read-only text can still be selected and copied, and its view still hears
  clicks (a pill's double-click follows it).
- **TextKit 2.** AppKit gives a text view whose class overrides `draw(_:)` TextKit 1, so
  `DetailTextView` draws its placeholder in `drawBackground(in:)`, and a subclass that needs TextKit
  2 (pills are attachments, laid out as the canvas lays them out) keeps it. The box builds its
  scroll view by hand around the view `make` returns: `scrollableTextView()` would make the class
  with `init(frame:)`, and a plugin's view may need more to be made.
- **The font** is `DetailStyle.textFont`, the panel's text (11 pt), which a plugin's style takes
  (`MentionStyle.panelText`).

### Focus and hosting

- **Typing in the panel never triggers a shortcut.** Keyboard answers only keys typed on the
  canvas, so "n" typed into a title is text, and Delete and Return in a panel field never delete or
  edit the selected shape.
- **The keyboard goes back to the canvas** on a click on the canvas; on Escape in the panel, which
  drops any number draft first (but for a text view that holds keys: Escape with the `@` picker
  or a code editor's completions open closes the list); and on its own when the panel removes the control that had the
  keyboard (switching tabs, collapsing its section, a `when` hiding it, or a new selection), or is
  hidden with it (View › Hide Inspector, which hides the panel without removing it).
  Otherwise the keyboard would land on the window, and shortcuts would stop. Collapsing an
  unrelated section leaves the field focused.
- **A number being typed lands on its shape** before another board is shown: the panel hears
  `boardWillChange` and commits the draft, as Return would, while its shape is still there to
  write to. (Escape still drops it.)
- **Inside the panel**, Tab moves between text fields (a `DetailTextArea` takes Tab as text, a
  `DetailCodeEditor` as two spaces), and Return commits a number and keeps the field; in the header's title field (`DetailHeaderField`),
  Return is done renaming, and gives the keyboard back to the canvas. Checkboxes don't take the
  keyboard (the macOS default without Full Keyboard Access); a pop-up, segmented control or stepper
  that has it keeps
  shortcuts from the canvas until Escape.
- **Zoom** (⌘=, ⌘-, ⌘0, and ⇧1 and ⇧2 except in text, where they type) works whatever has the
  keyboard: the board's window controller answers the View menu's zoom items, and the toolbar's
  zoom menu, with the core's zoom commands and Selection's Zoom to Selection. So does Go › Back
  (⌘[).

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
selected shape, its status lines and what `shownWhile` hides, and rebuilds the shape's panel only
if any of them changed; dragging another shape costs one comparison (`./build.sh bench` holds the
layout of a subboard 100 notes mention, its Mentioned In tab showing, to 1 ms after a drag event
of another note and after a mentioner's rename). A section is rebuilt only when its own shape changes.
Only the current tab is built, a collapsed section's content isn't, and each kind's contributions
are gathered once.
For your part: sections read only their binding, `when`, `shownWhile` and status lines stay cheap,
and anything heavy goes in a service, kept per shape and redone for the shapes each commit's change
set names (`documentDidChange`), as `ValidationEngine` does.

## Context menus

A right-click on a shape (or a Control-click) opens a menu of what can be done to it. It's a
horizontal ([`Sources/ContextMenus`](../Sources/ContextMenus)) like the detail panel: it declares one
extension point, kinds and other plugins fill it, and the core only passes the click along. A
right-click on a subboard:

```
┌─────────────────────────┐
│ Open                    │  a feature's (Boards, through opensBoard): first, as Finder's is
├─────────────────────────┤
│ Cut                     │  the canvas's (Clipboard): Paste once there's something to paste
│ Copy                    │
│ Paste                   │
├─────────────────────────┤
│ Arrange               ▸ │  every shape's (Reordering): Bring to Front, Bring Forward,
├─────────────────────────┤    Send Backward, Send to Back
│ Lock                    │  the canvas's (Locking): Unlock once every shape it's for is locked
├─────────────────────────┤
│ Delete                  │  the canvas's (ContextMenus' own): Selection's `.delete`, last
└─────────────────────────┘
```

A sticky note's is the same without Open. Every shape has Delete, ContextMenus' own item for the
canvas (in `SelectionMenuGroup`, order 400, last, after Lock, as Keynote has it), which runs
Selection's `.delete` on the menu's shapes, as the Delete key does: a locked one shakes. As shipped,
every shape has Lock (or Unlock) too, and every copyable shape Cut and Copy, items for the canvas,
which are in every menu with shapes; an arrow's menu is those alone, since Arrange leaves it out. A
shape something mentions has Show What Mentions too, after its own items (Mentions', for the
canvas, in `MentionsMenuGroup`, order 50), which goes to what mentions it
([What mentions a shape](#what-mentions-a-shape)). On empty canvas the menu is the canvas's items
that apply there alone: Paste, once there's something to paste, which lands centered where the
menu was asked for (⌘V keeps its own rule), and Select All (ContextMenus' own, Selection's
`.selectAll`) while the board has shapes. An empty board with nothing to paste has no menu: the
right-click does nothing.

### Contributing

| Sugar | For |
|---|---|
| `x.contextMenu { items }` | This kind's items, inside `registrar.shape { x in ... }`. A horizontal's opt-in sugar calls it too. |
| `registrar.contextMenu(P.self) { items }` | Another plugin's kind, typed as its own (bridges). |
| `x.contextMenu(of: P.self) { items }`, `registrar.contextMenu(of: P.self) { items }` | An [added property](#added-properties), over its value: on this kind's shapes that have one, or on every shape that has one. |
| `registrar.contextMenuForEveryShape(where:) { items }` | Every shape, over `AnyShapeRecord`. `where:` picks kinds by their definition, and so by capability (`{ !($0 is any PaintOrderAnchored) }`); `when:` picks shapes (`{ $0.box != nil }` for those with a frame). |
| `registrar.contextMenuForCanvas { items }` | Items that aren't one shape's (Cut, Copy, Paste; Show What Mentions, since whether a shape is mentioned is what a service knows; Delete and Select All), over the menu's `MenuSubject`: its shapes (none on empty canvas), where it was asked for (`point`, world units) and the editor. In every menu, after the shapes' own in their groups' order, and alone on empty canvas. Each is asked once per menu, not per shape. |

Boards' Open, which a board-owning kind's opt-in brings it ([OpensBoard.swift](../Sources/Boards/OpensBoard.swift)):

```swift
contextMenu {
    MenuItem("Open", in: BoardsMenuGroup.self) { ids, editor in
        if let first = ids.first { editor.open(first) }
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
  `when: { $0.editor.canPaste }`, Mentions' Show What Mentions `when: { subject in
  subject.shapes.contains(where: mentions.isMentioned) }`), and takes the `perform` form, which
  gets the subject's shapes, or the `edit` form, which is handed the subject itself, for an item
  that needs where the menu was asked for (Clipboard's Paste: `{ subject in
  subject.editor.paste(centeredAt: subject.point) }`). Ask whether an item shows of the subject,
  not of `editor.canPerform`: the selection is the menu's shapes only once the menu is made.
- **`Submenu(title) { items }`** shows when any of its items does.
- **Groups are types**, like tabs: a separator falls between groups, which sort by `order`, then by
  first appearance, in the tabs' bands. An item names its group with `in:`; the default is
  `ShapeMenuGroup`.

  | Order | Groups |
  |---|---|
  | 0 (the default) | A kind's own items (`ShapeMenuGroup`) |
  | 50 | A horizontal's feature, on the kinds that opt in (a flag's `FlagMenuGroup`, [below](#something-the-user-turns-on)), or on the shapes it knows something of (`MentionsMenuGroup`) |
  | 100 and up | Shared by every kind (`ClipboardMenuGroup`, 100; `ReorderMenuGroup`, 200; `LockMenuGroup`, 300; `SelectionMenuGroup`, 400, ContextMenus' own Delete and Select All) |

- **Keyed.** Each item claims its target, group and `id` (the title by default), and an item in a
  submenu its path, so two plugins adding one item to a kind are a `conflict`
  ("subboard Open"), and so are two for every shape. A kind's own item replaces an
  every-shape one with the same group and id.

### A feature that comes with menu items: Boards

The pattern of the detail panel's feature tabs, again. Boards' opt-in sugar contributes to its own
point, the panel's, and this one, so `sub.opensBoard(…)` brings the Board tab and Open, the item
above ([A horizontal's feature tab](#a-horizontals-feature-tab-boards)). Its group,
`BoardsMenuGroup`, is at order 0, so Open comes first, as Finder's does; a feature's group is
usually at 50. Items over an added property's value go in `contextMenu(of: P.self) { … }`, as its
sections go in `details(of:)`: a flag's Flagged is over the flag
([Something the user turns on](#something-the-user-turns-on)).

A future horizontal does the same inside its own sugar: its point, its tab, its menu items (over
its property's value, if it adds one), one line on the kind. The edge comes with it: Boards imports
ContextMenus, so a list with a kind that opens boards needs `ContextMenusPlugin` too. A feature
whose menu items should be optional puts them in a bridge instead.

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
| On the rest of the canvas | The canvas's items alone (Paste, landing centered on the click; Select All while the board has shapes); the selection stays. |
| Where nothing applies | Nothing: no menu, and the selection and any editing stay. With Selection installed every shape has Delete, so that's empty canvas on an empty board, or wherever every item that applies is left out by `when`. |
| During a press | Nothing. |

The select tool's hit rule finds the shape, so unselectable shapes are seen through. Opening a menu
ends editing. A right-click opens the menu in any tool; a Control-click only in the select tool,
since other tools may read ⌃ as a modifier.

With several shapes, an item shows when every one of them shows it: the same group and id, whichever
plugin contributed it for each kind, so two flaggable kinds ([below](#something-the-user-turns-on)),
selected together, share Flagged. It's enabled when it is for any of them, and runs on those: each
kind's own `edit`, all in one transaction, then each contribution's `perform` once, with its shapes.
It's checked (✓) when every shape checks it and mixed (–) when some do; a kind whose item has no
`isChecked` counts as unchecked. A submenu holds what its items resolve to. In a group, a kind's own
items come first, then every shape's, each in plugin and builder order, then the canvas's. A shape's
own item with a canvas item's group and id takes its place, shown or not, as a kind's own item takes
an every-shape one's.

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
│   ▤ Groceries                       │ a titled note: its title (Titles), not its text
│   {} Customer                    2  │ a schema card: its name, and how many fields
│   {} Untitled                     ● │   no name: the placeholder, dimmed; the dot, red: its error (ValidationContents)
│   ▭ Rectangle                       │ a kind with no row: its label and symbol, dimmed while untitled
│   ▭ Server room                     │   or its title, here RectangleTitles'
│   ↗ Arrow                           │ an arrow that starts on nothing, at the top
└─────────────────────────────────────┘
```

### A kind's row

StickyNotes' row, in full ([NoteRow.swift](../Sources/StickyNotes/NoteRow.swift)):

```swift
note.contentsRow(affected: MentionRows.affected) { note, context in
    ContentsLabel(context.plainText(note.props.text), placeholder: "Empty Note", color: .yellow)
}
```

- **The row is a view the kind builds**, usually a `ContentsLabel`: a title on one line (each run of
  whitespace folds into a space), a placeholder shown dimmed when the title is blank, an SF Symbol
  (the kind's, unless the row gives one) with an optional color, and a badge of a few
  characters at the trailing end ("12"). Its text is its tooltip (`label.help`, none for a
  placeholder; past 200 characters, cut between words with "…"), for a row the list cuts short, in
  the list and in a crumb's menu. The list owns everything around it: row
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
- **Without a row**, a kind is listed by its label and symbol (`registry.label(of:)`: "Arrow",
  which Arrows declares, "Rectangle", its tool's), the fallback the detail panel's header uses. Where another
  plugin names the kind's rows (`contentsTitle`, below) that label is a placeholder, dimmed until a
  shape is named, as an untitled note's is, so unnamed rectangles don't read as named "Rectangle";
  a kind nobody names (an arrow) shows it at full strength. A kind can keep that
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
| `onClick` | Return on a picked row opens its shape, as Return on the canvas does (Selection's `editor.open`); a double-click too, where the list stays on screen ([Opening a row](#whats-listed-and-selecting)) |
| `getGroupChildren` | Not built yet |
| The "other" row (type and id) | The kind's label and symbol (`registry.label(of:)`) |

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
    context.service(RefIndex.self)?.refs(to: changes.shapeIDs.union(changes.elsewhere)) ?? []
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
- **Other boards.** A row may read a shape on any board of the file (a mention of a shape inside a
  subboard: `editor.file.record(id)` finds it). What a commit did beyond its board is in
  `changes.elsewhere` (the shapes of the boards a deletion took or a paste brought, and those a
  `transact(on:)` changed), so `affected` looks there too, as `RefIndex` does above: deleting a
  subboard remakes the rows of the refs to what was inside it. The table of contents keeps each
  board's rows for going back to it; on going back to a board as it was left, it hands `affected`
  what changed on the other boards meanwhile, as `elsewhere` (on the next read, once every service
  has followed the switch), so a row that reads a shape renamed, deleted or brought back by undo
  there is made again, and the rest are taken back as they were. It keeps what was touched since
  the board kept longest ago was left, a revision per shape, only while boards are kept and some
  row or mark reads other shapes: a commit costs one more write per shape it touched.
- **`when` and `nestedUnder` still read only the shape**, and `contentsTitle` still names the row:
  a name that isn't blank takes the place of the label's title (a titled note shows its title).
- **What other shapes are, never where they are.** Such a row reads other shapes' names and state,
  not their positions: on a board that isn't shown, where `affected` can't say which rows a commit
  changes, [another board's outline](#another-boards-outline) makes these rows again after a commit
  that did more than move shapes, and not after a move (a drag's every event).
- `registrar.contentsRow(OtherKind.self, affected:) { shape, context in ... }` is the same for
  another plugin's kind (bridges). The row that reads only its shape keeps its forms,
  `x.contentsRow { ... }` and `x.contentsRow(when:nestedUnder:)`.

### Marks: ValidationContents

A mark is a small dot, or an SF Symbol (`ContentsMark(symbol:color:help:)`), at the trailing end
of a shape's row, from any plugin: a state worth seeing at a glance down the list. [ValidationContents](../Sources/ValidationContents/ValidationContents.swift),
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
- **`where`** keeps a mark for every shape to the kinds that opted into what it marks, as an
  adornment's does: a `ContentsKind`, asked once per kind, with `holds(P.self)` for the added
  properties it holds. Locking marks a locked shape's row with a lock, on the kinds that can be
  locked, reading only the record:

  ```swift
  registrar.contentsMarkForEveryShape(where: { $0.holds(LockedProperty.self) }) { shape, _ in
      shape.isLocked ? ContentsMark(symbol: "lock.fill", color: .secondary, help: "Locked") : nil
  }
  ```
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
  in its NSTableView delegate", which it says will become an assert. So a commit that brings rows
  in at more than one place replaces the rows too (a `canvas draw` that adds a shape and connects
  two shapes far apart in the list; deleting a note that two arrows start from, as their rows come
  out from under it), while one that brings them in at one place (an arrow drawn, a paste) keeps
  the rows it has. It does so in a list of any length: a list of 250 rows logs it too, rows brought
  in around those kept, and not when they're replaced. AppKit still logs it when a list first
  shows 200 rows or more (it measures 200 at a time). Replaced rows start collapsed again, as they
  do when what's listed changes, and a row that goes lets go only of a hover the pointer on it set
  (`ContentsState.endHover`), never one the canvas set, so the shape under the pointer stays
  outlined.
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
- **The board shown.** It lists `editor.document`, so the board shown and nothing under it. Each
  board's rows, and its listing of every row, are kept for the boards shown last (a `BoardStash`),
  and taken back on the way back to one that hasn't changed since, so going back makes no row. A
  scope pinned by selecting rows or Show All was the board left's, and goes. Another board's rows
  replace this one's in one run, whatever's listed on either (the list's id is the board, the scope
  and how many times a commit has brought rows in at several places, `ContentsListID`).
- **The heading.** The header says "Board" over the whole board. Whoever places the list can name
  the board instead: `TableOfContentsView(editor:onExit:heading:)` takes
  `heading: (CanvasEditor) -> ContentsHeading?`, a title, a symbol before it, and `up`, a command
  the header offers as a button while it can run (`editor.canPerform`): an arrow turning up, not a
  chevron, which in a list's disclosure column reads as collapsing; `upTitle` names it to VoiceOver
  ("Up" by default) and `upHelp` is its tooltip, the title and its key as a tool's is. The table of
  contents doesn't know what a board is; the heading's maker does. Filtered, the header is
  "Selection" with Show All, whatever the heading.
- **Opening a row.** A double-click or Return on a row opens its shape, as Return on the canvas
  does: `ContentsState.open(_:)`, the list's primary action, selects it and runs Selection's
  `editor.open` (entering the board it owns, editing it, whatever its kind opens to; one row, that
  `editor.canOpen`; several open nothing). A single click still selects and zooms. That's the list
  on its own; in the app's panel, picking one row selects its shape, so the panel shows that
  shape's panel in the list's place (the list is gone before a double-click's second click) and
  hands the keyboard to the canvas, where Return opens it.
- **Going back.** A row's click is a step in Selection's history like any other change of the
  selection, so the back button in the shape's header (or Go › Back, ⌘[) brings the list back,
  with the view as it was before the zoom, as data-canvas's back button does.
- **The keyboard.** A click gives the list the keyboard, as a source list does: the arrow keys move
  through the rows, Delete runs the `.delete` command (deleting the selected shapes, as Delete on
  the canvas does), and Escape gives the keyboard back to the canvas (`onExit`). So does hiding the panel while the list has the keyboard.
- **Headless**, `ContentsState` (`editor.tableOfContents`) is all of it: `entries` (the rows, a tree),
  `scope`, `select(_:)`, `showAll()`, and the rows' hover: `hover(_:)` and `endHover(_:)` as the
  pointer moves onto a row and off it, and `isHovered(_:)` for whether a row shows as hovered. Tests
  read a row's text, symbol and badge through `entry.label`, and its marks through `entry.marks`;
  `open(_:)` is a row's primary action. In debug builds, `rowsRedrawn` counts how often the list
  has asked a row for its view, and `rowsMade` how many rows it has made.

### Another board's outline

The list is the board shown's, as the selection filters it. A view of any board of the file lists
that board's rows through `ContentsState.outline(of: board)`: the rows `entries` would list there
with nothing selected, nested alike, whichever board is shown. What the path's crumb menus show
(Boards: a crumb's menu is its own board, [A crumb's menu](#a-crumbs-menu)).

```swift
ContentsOutline(editor: editor, board: board, highlighted: next, maxHeight: 348) { id in
    editor.goTo([id])
}
```

- **The rows are the list's**, each as its kind draws it (`contentsRow`, named by `contentsTitle`),
  less their marks, which are the board shown's: validation checks only it.
- **Made once, kept while the board is as it was.** The first read makes every row of the board;
  another is taken back while the board's revision is unchanged and it's on the path to the board
  shown (showing a board forgets the outlines of boards off its path). A read after a commit that
  did more than move shapes makes again the rows that read more than their shapes (a note's, with
  the live names of what it mentions: its kind's `affected` answers only for the board shown, so
  every such row is made again, whatever else the commit touched), and keeps each whose label is
  the same; a move (a drag's every event) names nothing anew, and makes none. Reading it ties the
  reader to every commit, as `entries` does. `./build.sh bench` holds the reads after a move and a
  rename on a subboard under a root of 10,000 to 1 ms and a frame; the first read there is some
  23 ms.
- **`ContentsOutline(editor:board:highlighted:maxHeight:onPick:)`** shows it, for a small panel:
  one line a row, 24 points each, as tall as its rows up to `maxHeight`, past which it scrolls
  (only the rows in view are made into views); nested rows behind a disclosure triangle, collapsed
  until it's opened, as in the list; `highlighted`'s row tinted as a hovered row is in the list,
  and the row under the pointer lit. A click on a row picks its shape (`onPick`), and what that
  does is the host's. It opens at the top, as data-canvas's menus do (scrolling a lazy stack to a
  row far down lays out the rows before it: some 70 ms to the last of 10,000). Nothing without the
  plugin, or for a board with no rows.

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
pill, a lock. It's a horizontal ([`Sources/Adornments`](../Sources/Adornments))
through which any plugin puts one on any kind, its own, another plugin's, or every shape. Adornments
lays out each shape's, so none overlaps another, draws them, and makes each its shape's for the
pointer. The core has never heard of one.

```
╭─────────────────────────╮ ╭────╮
│ Groceries for the week… │ │lock│    the row, 9 points above the top edge, 18 tall: a title's
╰─────────────────────────╯ ╰────╯      pill at its left end, a lock at its right end, 4 apart
                           ╭───────╮
┌──────────────────────────│ ☑ 1/3 │  the corner, 16 tall, centered on the top edge: a
│ Buy milk                 ╰───────╯    tally, reaching 6 points past the right edge
│                                │
└────────────────────────────────┘
```

An adornment is never a shape or a record. What it shows is made from its shape's data (its
props, an added property, what the registry says of its kind), so it moves, copies, deletes and
saves with the shape, and there's nothing to attach, keep in step or clean up. Neither of the two
shipped is placed by the plugin that defines the note: Titles places the pill and Locking the
lock, on every shape of the kinds that take part.

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
capabilities: `{ $0.definition is any Editable }`), the `registry` (so what else it takes part in),
and `holds(P.self)`, whether its shapes hold an added property, so an adornment that shows one goes
where the property does (Locking's lock: `{ $0.holds(LockedProperty.self) }`, the kinds that can be
locked). Titles places its pill this way, on the kinds that opted into its own point with a title
that shows one (`$0.registry.showsTitlePill($0.kind)`, [Titles](#a-horizontal-plugin)). So
`note.title()` brings the pill, a kind that draws its own says `pill: false`, and the report says
Titles, which defines no kind, places the pill (`adornment TitlePill → every shape`). A bridge puts
one on a kind it doesn't define, typed:

```swift
public enum SizeBadge {}
extension SizeBadge: Adornment {
    public static var placement: AdornmentPlacement { .onTopRightCorner }
}

registrar.adornment(SizeBadge.self, on: Rectangle.self) { rectangle in AdornmentLabel("\(Int(rectangle.frame.width)) pt") }
```

### Places

Three places, each from the shape's bounds (its geometry's, axis-aligned, so a kind without a frame
has them too), in view points:

| `AdornmentPlacement` | Where | Shipped |
|---|---|---|
| `.aboveTopLeft` | The row just above the top edge, 18 points tall and 9 above it, from its left end rightward, in the room its right end leaves. Text gives way, ending in "…", and needs 30 points, and a symbol's place and gap before it more (`Item.lead`), so it's never a symbol alone: with less, it's left out, and so is what comes after it. | A title's pill |
| `.aboveTopRight` | The same row, from its right end (the shape's right edge) leftward, whole: on a shape too narrow for it, past the shape's left edge. | A lock |
| `.onTopRightCorner` | The top-right corner: 16 points tall, centered on the top edge, from 6 points past the right edge leftward. | None (a tally, as above) |

In a place, adornments sit 4 points apart. They keep their size on screen down to 25% zoom, and
shrink with the shapes below it (0.4× at 10%); below 35% they're drawn blank on a shape drawn as a
skeleton, and in full on the shape being edited ([the label](#the-label)). A shape without an
outline (nothing drawn) shows none, and neither does one its
board keeps aside. On a 200-point note, in points from its top-left
corner, y down:

| The note | Laid out |
|---|---|
| Unlocked, with a long title | pill (0, −27, 200, 18) |
| Locked, with a long title | lock (182, −27, 18, 18); pill (0, −27, 178, 18) |
| With a tally on its corner | tally (206 − w, −8, w, 16), `w` its text's width and 10 |
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
| 50 | One a horizontal's feature brings to the kinds that opt in (`TitlePill`) |
| 300 | A state of the shape that comes and goes (`LockChip`): farthest out, so the others keep their places |

So a flag a kind shows of its own keeps its place at the row's right end whether a lock is beside it
or not. Equal orders fall back to plugin order, so unrelated plugins needn't agree on numbers.

### The label

`AdornmentLabel` is what an adornment shows on one shape. Adornments draws every one, so every
plugin's look alike, as `ContentsLabel` keeps rows alike:

- **Text**, `AdornmentLabel("Groceries")`: one line (each run of whitespace, newlines included,
  folds into a space; blank shows nothing), white, in a capsule. In the row it's 11-point medium,
  7 points in from the capsule's ends; on the corner, 10-point semibold figures that line up, 5 in.
  With `systemImage:`, `AdornmentLabel("Order", systemImage: "curlybraces")`, a small SF Symbol
  goes before it (a kind's mark: Titles' pill on a kind that asks, `symbolInPill`), two points
  smaller than the text, semibold, white at 75%, centered in a place as wide as the text is tall
  (11 points in the row, 10 on the corner), 3 points before the text.
- **A symbol**, `AdornmentLabel(systemImage: "lock.fill")`: an SF Symbol, bold and white, in a
  disc as tall as its place, half as tall as the disc.
- **`tone`**: `.neutral` (the default), a title pill's dark gray; or `.success`, green, for
  something done (a tally with every item done).
- **`opacity(_:)`**: the same label drawn lighter, 0 to 1 (Locking's open lock, fading).

A clickable one draws lighter hovered and darker pressed. A label can't draw itself (a sparkline):
that's [not built yet](#not-built-yet).

**Zoomed out**, below 35%, each label follows its own shape's level (`editor.drawsSkeleton(of:)`).
On a shape drawn as a [skeleton](#skeletons) it's drawn blank: its capsule or its disc alone, no
text or symbol, in an opaque pale gray of the skeletons' hue, a little off the canvas
(`AdornmentStyle.blankFill`, sRGB 0.84, 0.85, 0.86 on the light canvas and 0.21, 0.22, 0.23 on the
dark: lighter than a shape's skeleton on the light one, darker on the dark), so it's there without
weighing more than the greeked text beside it, and stays gray over a note's yellow (`.success` as
pale a green: 0.70, 0.86, 0.74 light, 0.18, 0.29, 0.21 dark). Being opaque, it lets no grid dot
show through. It keeps its opacity (an open lock still fades) and a clickable one's lighter hovered and darker
pressed. Text's capsule is as long as its columns (`SkeletonText.columns(of:)`: a CJK character or
an emoji two, a combining mark none) at its place's average column advance (measured once, from a
sample, in the place's font), after its symbol's place if it has one, with its padding, and laid out as a measured one is (at the row's left
end, it gives way), so nothing is set or measured on a skeleton: "iiiiiiii" and "WWWWWWWW" are as
long, and "東京の会議メモ" is about as long as in full (91 points blank, 90 in full, as measured).
The shape being edited is drawn in full, so its labels are too, drawn and pointed at in full, while
its neighbors' are blank.

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

Adornments makes a shape's labels once, whatever the zoom, and keeps them until a commit names the
shape (its `ChangeSet`) or `adornmentsDidChange` does; drawn in full, it measures them too
([Drawing and cost](#drawing-and-cost)). So a label read from anything else (another
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
  registry is frozen), and keeps each shape's labels, made once whatever the zoom, with how long
  each is drawn blank, and, apart, the faces of those drawn or pointed at in full (the text set and
  measured, the symbol's image), dropping both for the shapes each commit's change set names. As
  the canvas starts drawing skeletons (`drawsSkeletonsDidChange`) it lets the faces go (the shape
  being edited makes its own again as it's drawn); zoomed back in, it makes the faces of what a
  frame draws. It doesn't look under the pointer itself: Selection hears the level change too and
  looks again, buttons first, and the layouts answer at the new level whichever hears first. So
  zooming out over a thousand adorned shapes measures nothing, and zooming in again measures what's
  in view. Where they go is worked out when it's asked, from what's kept, since it follows the zoom
  and geometry that follows other shapes: a few additions per adorned shape in view. So a frame
  costs a lookup and the drawing per adorned shape in view, and a drag the labels of what moves.
  Once labels are kept, a frame allocates nothing per adorned shape: one buffer of slots a frame
  (`AdornmentLayout.slots(of:width:into:)`), and the hovered and pressed buttons read once and
  compared field by field, never boxed (at 10% on the 10,000-shape bench board, 558 adorned shapes
  and 155 locks in view, the overlay took about a millisecond, as measured, with no array a shape
  or box a lock). `./build.sh bench` holds a hover and a drag at 10,000 shapes, with pills and locks
  in view, and a hover onto a pill, to a frame (16 ms).
- **Blank, a run at a time.** Zoomed out, where thousands are in view, blank labels are filled a
  run at a time: one path while they're alike (tone, look and opacity), filled once the next isn't,
  in paint order, so what's over what is as when each is filled alone, and, being opaque, where two
  meet is no darker. A capsule's ends are flattened to chords within 0.2 device pixels, since Core
  Graphics fills a path of many curves more slowly than filling each alone: 7,200 labels at 10%
  took some 5 ms as lines in one path, where as curves they took 12 filled one at a time and 24 in
  one path. A label drawn in full among them (the shape being edited's) fills the run first, so
  it's over the blank ones behind it.

### Pointing

| Adornment | What the pointer does |
|---|---|
| A `ClickableAdornment` (the lock) | It's a [canvas button](#canvas-buttons), through Adornments' own source: in the select tool, a press and a release on it click it (its type's `click(on:in:)`), before handles and shapes; dragged off, nothing, and Escape lets go. The pointing hand shows over it, and it draws lighter hovered and darker pressed. In other tools it's only drawn. |
| Any other adornment (a pill) | It's its shape's ([DecorationHits](#drawn-for-a-shape-decorationhits)): hover hovers the shape, a press selects it and a drag moves it, a double-click edits it, and a right-click opens its menu. A clickable one (the lock) is its shape's only for the right-click, which offers Unlock; everything else on it is the button's (a double-click is two clicks). |

- **A hit** is within 3 points of the adornment's capsule, so a disc's is a circle, 12 points from
  its middle, and not its box's corner. Of one shape's adornments the nearest takes it; of several
  shapes', the front-most shape's, as they're drawn, so a front shape's pill over a back shape's
  lock takes the press. Hits go by where a shape is, not where a shake draws it, each shape's laid
  out at its level (`editor.drawsSkeleton(of:)`), as it's drawn: on a skeleton, a blank label is
  hit where its capsule is, so a point past a blank title's end, which the title in full would
  cover, hits nothing, and a blank lock still unlocks; the shape being edited's are hit in full. An
  unselectable shape's adornments are seen through, as it is, but a button isn't: a lock is clicked
  whatever its shape.
- **`editor.hoveredButton`** and `editor.pressedButton` hold an `AdornmentButton` on a clickable
  one: `AdornmentButton(LockChip.self, on: id)`, the type and the shape.
- **`editor.adornmentFrames(of: id)`** is where each of a shape's adornments is now: an
  `AdornmentFrame` each (`adornment`, as `.of(TitlePill.self)`; its `label`; and its `rect`, in
  world units at the current zoom, where the shape is, blank on a skeleton), in the order they're
  claimed, leaving out those without room. It's empty for a shape with none.

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
one line, `note.flaggable()`, as `note.title()` does. What that gives:

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
lends four generic things: commands (`.cut`, `.copy` and `.paste`, which Edit › Cut, Copy and
Paste send), shape [metadata](#metadata), the `ShapeReferencing` [capability](#capabilities), and
`CanvasFile.isUnused(_:)`, whether anything in the file goes by an id, which a paste asks before
giving a shape back the id it had.

| | Does |
|---|---|
| ⌘C, Edit › Copy, Copy | Puts copies of the selection's copyable shapes on the pasteboard, back to front, with what the boards they own hold. The board doesn't change. |
| ⌘X, Edit › Cut, Cut | Copies, marked as a cut's, then deletes what it copied whole, in one transaction. What can't be copied stays, and so does a shape whose board holds one, and a [locked](#locking) shape, copied all the same (it shakes, as with Delete). |
| ⌘V, Edit › Paste, Paste | Puts what's on the pasteboard on top of the board, and selects it: what a copy put there as copies, with new ids all the way down; what a cut put there moved, under the ids it had. |

- **Copies get new ids, and remember their originals.** Each copy's metadata names the shape it
  was copied from: `record.copiedFrom`, which is `meta[CopiedFrom.self]?.shape`, and its board
  keeps it. That's the shape the copy was made from: a copy, if a copy was copied; in whichever
  board it was copied from, this one or another; and maybe gone since. Pasting a copy twice makes
  two copies of the same shapes. The rest of a shape's metadata comes with it, and so do its
  [added properties](#added-properties)' values: a locked shape's copy is locked, as tldraw's is. A paste moves its copies (`translate`) in the transaction that puts them
  in, which a lock doesn't stop.
- **Cut and paste is a move.** A cut marks what it writes as a cut's: a token beside the shapes,
  under a type of the app's own (`com.example.InfiniteCanvas.cut`), a fresh UUID each cut, in the
  same write. A copy writes none, and any later write clears it, this app's or another's. A paste
  of what a cut put there keeps each id nothing in the file goes by (`CanvasFile.isUnused`, the
  core's: no shape has it, no board is kept under it, and no entry that didn't read as a board is
  kept under the key its board would be written under), so the shapes the cut took come back as
  themselves, on whatever board the paste lands, and whatever names them (a
  [mention](#mentions-across-boards), on any board of the file) names them again. Such a shape gets
  no `CopiedFrom`: it's the same shape, moved, and keeps the metadata it had, an older
  `CopiedFrom` included, so a shape without one may still have been pasted. An id in use (the
  shapes an earlier paste of the same cut put down, or one whose deletion the cut had refused)
  makes that shape a copy, from the same map as the rest, so what's pasted names each of its
  shapes as pasted. There's no ledger of pastes: the first paste's shapes hold the ids, so pasting
  again copies, and undoing the first paste frees them. Pasted into another window, a cut moves
  there too, where the file doesn't use its ids. A binding from outside what was cut lets go of
  what the cut took, as it would of a deleted shape (a binding must be on its board), and the paste
  doesn't bind it again: an arrow to a note that moved stays where it's drawn, free. Only names
  survive a move.
- **Where a paste lands** is tldraw's: where the originals were, if any of them would be in view
  there; otherwise centered in the view, the shapes keeping their places among themselves. A paste
  in place lies exactly over its originals, as in tldraw and Figma. The context menu's Paste lands
  centered on its click instead (`editor.paste(centeredAt:)`, the menu's `point`), wherever what
  it pastes was copied from. Moving them is
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
  copies of the shapes copied with it, and goes on naming the rest. Across a tree of boards a paste
  passes names through the whole tree's map (`remappingReferences(_:naming:in:)`): a note at the top
  pasted with a subboard mentions the copy of a shape two boards down, and a note inside mentions the
  copy of the subboard it's in, while bindings stay on their own board.
- **Shapes that own boards** (`BoardOwning`) are copied with what they hold, all the way down:
  the board a copied shape owns, the boards its shapes own, and so on, read with
  `editor.contents(of:)`. On each board, the shapes that can be copied go, letting go of those left
  out on that board, and a shape left out takes the boards under it. A shape of a kind that owns no
  board is copied without whatever board a file keeps under its id. A paste renames every shape on
  every board from one map (a copy's to new ids, a move's to its own), so shapes inside stay bound
  to each other and name each other (an arrow on a subboard stays bound), and each copy, nested
  ones included, names its original. Each owner goes in with its boards, keyed by its id as pasted
  (`transaction.insert(_:contents:)`, one commit); only the top-level shapes are moved into place
  and selected. A copy's new ids make a new tree, so a subboard pasted onto its own board is a copy
  inside itself, never a loop. Cut deletes only the shapes copied whole: one whose boards held
  something that couldn't be copied stays, as an uncopyable shape does, with everything under it,
  and its id being in use, it pastes as a copy.
- **The pasteboard** holds a small board: `BoardCodec`'s JSON, each kind and added property at its version, under the
  app's own type. So one window can paste what another copied, a paste into a newer app migrates as
  opening a board does, and a kind the board doesn't install is left out of a paste, on any board,
  and with it the boards under it. With boards under the copied shapes it's a whole file,
  `CanvasFile`, at format 4, the boards under their owners' original ids; without, it's written
  as it always was, so an app that doesn't know boards pastes it, and one that doesn't know format
  4 pastes nothing. A pasted shape whose kind owns no board in this app gets none. Anything else
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
  redoing it brings back the same copies (the same ids, `copiedFrom` and all). Undoing a move's
  paste takes the shapes out and frees their ids (a paste after it moves them again), redoing it
  puts them back under them, and undoing the cut too puts the file back as it was, showing the
  board the cut was made on.
- **In the context menu**, Cut, Copy and Paste are items for the canvas
  (`registrar.contextMenuForCanvas`), in `ClipboardMenuGroup` (order 100, before Arrange), asked
  once per menu. Cut and Copy show when some of the menu's shapes can be copied, and act on those;
  Paste shows when something would paste, on shapes and on empty canvas, and lands where the menu
  was asked for.

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
corner, and a lock at the end of its row in the table of contents. Shapes are locked from the
context menu, and unlocked there or with a click on the chip, which shows the lock open for a
moment, where a click locks the shape again. It's a horizontal
([`Sources/Locking`](../Sources/Locking)) that every kind is in, built on Adornments, ContextMenus,
Selection and TableOfContents; the core has never heard of a lock. It lends two generic things, read-only shapes
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
registrar.contentsMarkForEveryShape(where: { $0.holds(LockedProperty.self) }) { shape, _ in  // a lock at the end of its row
    shape.isLocked ? ContentsMark(symbol: "lock.fill", color: .secondary, help: "Locked") : nil
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
  the rest; Return and a double-click don't edit it (a kind that opens some other way, into its
  board, still opens); it shows no handles; Arrange doesn't restack it;
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
  is drawn, never the shape: `editor.setDrawingOffset(_:for:)`. Every refused shape shakes, locked
  or not: a shape whose board holds a locked shape isn't deleted either, so it's the one that shakes.
- **Another board shown** has its own locks: `LockState` takes back the locked shapes it kept for
  the board when it was left (a `BoardStash`, while the board's revision is unchanged), else finds
  them again (one pass, about a millisecond at 10,000, which going back to a board shown lately
  never pays; `boardsScannedForLocks`, debug builds, counts the passes), and what was under way on
  the board left, its shakes and the locks showing open, stops there. A locked shape that owns a board is entered like any other:
  entering isn't a change to it.
- **The chip** is an 18-point disc with a lock, the dark of a title's pill, at the right end of the
  row just above the shape, ending at its right edge. Its order is 300, a state that comes and
  goes, so it's farthest out of what's at that end, and a title's pill at the other end stops 4
  points short of it. Adornments lays it out with the rest, keeps its size on screen down to 25%,
  draws it blank below 35% on a shape drawn as a [skeleton](#skeletons), as a locked shape always
  is, since it can't be edited (a disc with no lock, locked or open and fading, which a click unlocks
  or locks as ever: [the label](#the-label)), and draws it
  where its shape is drawn, so it shakes with it. A click within 3 points of its edge
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
  deleted by it; nor is a shape whose board, or a board under it, holds a read-only shape (as the
  Finder won't trash a folder holding a locked file), since deleting it would take that shape too.
  The change is dropped, the rest of the transaction stands, and once it's done
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
[adornment](#adornments) (a title's pill, the lock chip) and Validation for its
outline. One that culls by the view can grow the rect by `context.worldDrawingReach`, the farthest
any shape is drawn from where it is (world units, zero unless one is), so a shape drawn into view
from just outside it is decorated there, as Adornments does. Everything else goes by where the
shape is: hit testing, handles, arrows bound to it, and pictures of the board (the minimap).
Deleting a shape drops its offset.

## Ports

Ports are data-canvas's: dots just outside the sides of the shape the pointer is over, from which a
drag draws an arrow to another shape. Not to any shape: each port is on a channel, a kind of
connection, and the arrow may end only on a shape that takes its channel, so a note links to a note
and a schema card to a schema card, never one to the other. It's a horizontal ([`Sources/Ports`](../Sources/Ports))
any kind opts into, built on Selection, whose [canvas buttons](#canvas-buttons) the dots are; the
core has never heard of a port, and Ports has never heard of an arrow: a bridge,
[ArrowPorts](#the-connector-arrowports), makes arrows what a drag from a port draws. The same
rules hold for a connection made by name, with no drag ([Connecting without a
drag](#connecting-without-a-drag)), as `canvas draw`'s edges are. Ports builds on
[Topology](#topology) too: a connection bound at both ends is an edge of the file's graph, of its
channel's type. Ports itself
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
    public static let summary: String? = "an arrow drawn on the note-link channel"
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

[Schema cards](#schema-cards) do the same with `SchemaLink` (`schema-link`, the card's accent), on
every side but the top too, where a titled card's pill is
([SchemaLinks.swift](../Sources/Schemas/SchemaLinks.swift)). The channels say nothing more yet: a
channel is where a connection's meaning would go (one schema referring to another, say), and it's
already what a connection is in Topology's graph: its edge type.

### Channels

- **A channel is a type** (`Channel`), as a tab or an added property is: its `id` (`ChannelID`),
  the color of its dots (`static var color`, computed, since colors aren't `Sendable`; gray by
  default), and what a connection drawn on it is, in a line (`static var summary`, nil by default:
  its edge type's [summary](#types)). The plugin that owns what a connection on it means declares it,
  `registrar.channel(C.self)` (the `Channels` point: a channel declared twice is a `conflict`), and
  kinds have ports on it by its type, so a plugin that gives a kind ports on another's channel
  imports that plugin's module. StickyNotes declares `NoteLink` for its notes, and Schemas
  `SchemaLink` for its cards; a channel that joins kinds of several plugins would be declared by the
  horizontal whose meaning it is (data-canvas's `registerHostChannel` calls come from such a
  feature), and given to their kinds by bridges.
- **A channel is an edge type too.** `registrar.channel(C.self)` also declares Topology's edge type
  of the same name (`note-link`), under the family of edges the connector draws (`arrow`,
  [below](#the-connector-arrowports)), a root without a connector: so a query for every arrow
  (`.within("arrow")`) finds those on every channel, and one for a channel finds its own. A
  channel's id that's another edge type's is a `conflict`, as two channels of one id are.
- **The id never changes once shipped**, since connections keep it. The id audit holds a
  `ChannelID` literal to the module that declares it, as it does a kind
  ([The module graph](#the-module-graph)).
- **What a connection knows is its channel**: `ChannelProperty` (key `channel`), an [added
  property](#added-properties) Ports declares and the connector's kind opts into. It has no
  default, so only a connection drawn on a channel has one, from a port or by name
  (`"added" : { "channel" : "note-link" }`), and an arrow drawn by `canvas draw` with `channel:
  none` has none. In the arrow's schema it's a string of at least
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
ports, and `channel note-link` on the declarer's.

**One port table.** Everything that asks about ports reads one table of each kind's ports
([PortTable.swift](../Sources/Ports/PortTable.swift): `KindPorts`, built on demand from the frozen
registry, and kept whole by each editor's `PortState`): the dots and a drag from one,
`editor.channel(of:endingAt:)`, `accepts`, and the lookups below. So a kind's channels are in one
order everywhere, plugin order: the order of the `ShapePorts` contributions in the plugin list,
whether one is for the kind or for every kind, and a kind's first contribution on a channel is its
only one there, its role and its sides. A drag and a connection asked for by name
([without a drag](#connecting-without-a-drag)) can't pick different channels. The lookups, on
`Registry`:

| Lookup | Is |
|---|---|
| `connectorKind`, `makesConnections` | The kind connections are (nil without a connector), and whether the connector makes them without a drag (it has `make` and `ends`). |
| `hasPorts(kind)`, `portChannels(of: kind)` | Whether a kind has ports on any channel, and on which, in the table's order. |
| `dotChannels(of: kind, side:)` | The channels a drag from its dot on that side starts connections on, as `Connection.channels` has them; with no side, all its dots' channels, each once. A `.target` port has no dot. |
| `takes(kind, channel, as: role, side:)`, `portSides(of: kind, on: channel, as: role)` | Whether its ports on a channel let it be a `.source` or a `.target` (on a side, if named), and on which sides. |
| `accepts(shape, on: channel, as: role)`, `declares(channel)` | `takes` for a shape (none for one kept aside), and whether some installed plugin declares the channel: what rules about connections already drawn go by. |
| `canConnect(id, in: shapes)` | The connector's `canConnect`, for a shape in any `ShapeContext`: the editor's, or a transaction's, which has the shapes it inserted. |
| `connection(_:existing:in:)`, `connectionEnds(of:)` | A connection made, or changed, without a drag, and the shapes one joins ([below](#connecting-without-a-drag)). |

`editor.channel(of: connection, endingAt: record)` is the channel a drag's connection would be
drawn on if it ended at a shape: the first of its channels the shape's kind takes as a target, and
nil for the shape it starts from, a shape kept aside, or one that takes none.

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
  kept aside, and the connector can start from it (`canConnect`, asked of the editor's shapes: an
  arrow can bind to it, so it's closed and isn't an arrow).
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
(`registrar.connects(K.self, edgeType: F.self, canConnect:make:ends:begin:)`, the `Connectors`
point, at most one). `K` is what connections are, and opts into `ChannelProperty`; `F` is the
family of edges they are in Topology's graph (an `EdgeType`, which this declares, and every
channel's type is under); `canConnect` says which shapes one
may start from and end on, in the `ShapeContext` it's given (the editor's, for the dots; a
transaction's, for a connection asked for by name); `make` and `ends`, both optional, connect
shapes [without a drag](#connecting-without-a-drag); and `begin`, given the drag's `Connection`
(the port's shape and side, the dot's channels in the port table's order, and where it was
pressed, in world units), returns the session that draws it, which the dot's press hands the drag
to, or nil to draw nothing. The bridge ([ArrowPorts.swift](../Sources/ArrowPorts/ArrowPorts.swift))
makes arrows the connector, though Arrows has never heard of a channel, and names their family of
edges:

```swift
public enum ArrowEdge {}

extension ArrowEdge: EdgeType {
    public static let id = EdgeTypeID(rawValue: Arrow.kind.rawValue)    // "arrow"
    public static let summary: String? = "an arrow bound at both ends, from the shape it starts on to the shape it ends on, whatever its arrowheads"
}

registrar.connects(Arrow.self, edgeType: ArrowEdge.self, canConnect: { id, shapes in shapes.canBindArrow(to: id) },
                   make: { request, existing, shapes in ArrowConnections.arrow(for: request, existing: existing, in: shapes) },
                   ends: { ArrowConnections.ends(of: $0) }) { connection, editor in
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
  center, and its end follows the pointer, binding by tldraw's rules as a re-aimed end does
  (arriving fast, it aims at a shape's center; arriving slowly, or after a 320 ms pause, at the
  spot; ⌥ runs all the way to it, ⌘ or ⌃ binds nothing, ⇧ snaps the angle), but only to a shape
  that takes one of the port's channels, looking through the rest to the shapes behind. Released
  on one, the arrow keeps the channel it's drawn on; released anywhere else, or on Escape, it's
  deleted, and nothing is drawn. Its binding hints are a re-aimed end's.
- **A drawn arrow keeps to its channel** (the rule): re-aimed or moved, each end binds only to a
  shape that takes the channel at that end, the start as a source and the end as a target,
  looking through the rest. An arrow without a channel (`canvas draw`'s `channel: none`), or with
  one no installed plugin declares (a board from an app with another plugin), binds wherever an arrow can.
- **It differs from tldraw's arrow tool** on three counts, as data-canvas's does: released free,
  the arrow is deleted, where tldraw's keeps a free end; its start binds the port's shape at its
  center, imprecise, with none of tldraw's hover and press timers; and the selection and the tool
  are left as they were, where tldraw selects its arrow and goes back to Select. And on one
  of the app's own: drawn to the canvas's edge, it scrolls it ([edge
  scrolling](#tools-and-sessions)), where tldraw's handle drags don't, so a shape off screen can be
  linked to without zooming out (where dots don't show, under 25%). The app had
  tldraw's arrow tool (A) too, until ports became the way to connect; it's gone, and a person
  draws arrows from ports alone, so kinds without ports (rectangles, subboards) are connected only
  by `canvas draw`, on no channel.
- **An arrow bound at both ends is an edge** ([Topology](#sources)): `connects` gives the
  connector's kind an edge source when it has `ends`, one edge from the shape it starts on to the
  one it ends on, typed by its channel (`note-link`) or, drawn on none (`channel: none`), by the
  family, `ArrowEdge` (`arrow`). An arrow with a free end carries none; one on a channel nobody
  declares carries an edge of that type, kept as written, unless it's another edge type's id (a
  file whose arrow says `mention`): a connection is never an edge of a type that isn't a channel's,
  so that one is the family's, and Mentions never takes an arrow for a mention. `ArrowEdge.id` is
  the arrow kind's name, taken from `Arrow.kind` rather than written again, since the id audit
  gives `"arrow"` to Arrows. A connector without `ends` carries no edges.

What Arrows lends, it lends any plugin, and it knows no channel
([ArrowConnecting.swift](../Sources/Arrows/ArrowConnecting.swift)):

- **`ArrowBindingRules`** (`registrar.arrowBindingRule { query in ... }`, a list) is tldraw's
  canBind: an end binds only to a shape every rule allows, looking through the rest. A rule gets an
  `ArrowBindingQuery`: the arrow as it is (its props and added values), the end, a shape under the
  end, and the registry. It's asked wherever an end binds: drawn from a port, re-aimed (the precise
  timer and a modifier's change included) or moved alone (`beginTranslation`'s probe), and only of the shapes
  the point hits, but as the pointer moves, so keep it cheap. With no rule nothing is filtered,
  and arrows behave as they did before.
- **`shapes.canBindArrow(to:)`**, on any `ShapeContext` (and `editor.canBindArrow(to:)`, on the
  editor's), is whether an arrow can bind to a shape: it's there, it's closed, and it isn't an
  arrow. **`registry.arrowMayBind(arrow, end, to: shape)`** is whether the binding rules let an
  end bind to a shape, the same check a dragged end's targeting and a lone arrow's translation make
  (`ArrowBindingQuery.isAllowed`), for an arrow made without a pointer.
- **`editor.beginArrow(from:at:canBind:complete:)`** draws an arrow for another plugin's gesture:
  it inserts one, its start bound to the shape (imprecise) and its end at `origin`, and returns the
  session that drags its end, for the caller to hand the drag to (nil if an arrow can't bind to the
  shape). Released bound, `complete` gets the arrow's record and the shape its end is bound to, in
  the transaction that finishes it.
- **`BindingHintsOverlay`** draws the hints of the arrow being dragged, else the selected arrow's,
  so an arrow drawn from a port, which leaves the selection alone, hints as a re-aimed one does.

### Connecting without a drag

A connection can be asked for by name, as
[`canvas draw`](#edges-and-their-channels-portedges)'s edges are:
`registry.connection(request, existing:, in: shapes)`, which the connector's `make` answers. A
`ConnectionRequest` says from which shape to which, aimed at which of their sides (none: where the
connector aims by itself, an arrow at the shape's center), on which channel (none: a plain
connection), and whether it has a head at its start too. Ports only
passes it on: the caller picks the channel, as a drag from a port would (`dotChannels`, `takes`),
and asks `canConnect` of both ends first (`registry.canConnect(_:in:)`). What comes back:

- **A new connection** (`existing` nil), not inserted: the caller inserts it, in the transaction
  whose shapes `shapes` are, so either end may be a shape that transaction inserted.
- **`existing` changed** as the request says: only the sides it names, and its heads, keeping its
  id, its curve, its channel and everything plugins keep about it, for
  `transaction.update(existing.id) { $0 = made }`, which keeps its place in the stack. When
  nothing would change it's `existing` itself (a record rebuilt outside the core has no stacking
  key, so it would never equal the one on the board), so `==` tells an unchanged one.
- **Nil** without a connector, or one without `make`, when `existing` isn't a connection, or when
  the connector refuses (an arrow can't bind to an end, or a binding rule won't let it).

`registry.connectionEnds(of: record)` is which shapes a connection starts and ends on, by the
connector's `ends`: nil for anything else, or one not bound at both ends.

ArrowPorts' `make` (`ArrowConnections`) binds both ends: an end with no side named at its shape's
center, imprecise, as a port's drag starts one, and a named side at its middle, precise but not
exact, so the arrow stops at the outline with its head's gap, as an end dragged in slowly does. Where a named side faces away from the other shape, the arrow still leaves by the side facing
it: an end is clipped where the line first crosses the outline, as tldraw's is. A changed arrow
rebinds only the ends the request names a side for (or whose shape isn't the one it's bound to).
A new one's channel is set first, so the binding rules, asked of both ends
(`registry.arrowMayBind`), see the channel it's drawn on; both ends on one shape at one anchor
would draw nothing, so one moves off it by 0.05, as a dragged end moves off the other. Its `ends` are
the shapes its two bindings name. An arrow made this way is an arrow like any other: re-aimed,
moved and kept to its channel as the rest are.

Ports are the part of data-canvas's that notes and schema cards need to prove the API; the rest is in
[Not built yet](#not-built-yet).

## Mentions

Mentions ([`Sources/Mentions`](../Sources/Mentions)) lets text mention other shapes: `@` in a
note, a few letters of another note's title, Return, and the note says "Ask ⟨▤ Ship the beta⟩
first", the mention an inline pill with the note's symbol and name. It's a horizontal on
Selection, the context menu, the detail panel, the table of contents, Titles and [Topology](#topology) (each mention is an edge of the
file's graph), and two kinds opt
in: sticky notes, whose text holds mentions and which can be mentioned, and subboards, which can
be mentioned (following a mention of one enters it). A mentioned shape's panel lists what mentions
it, and its context menu goes to what does. The core knows no mention; what Mentions needs of it
is generic: [names](#values-that-name-shapes) of shapes that may outlive them,
[faces](#faces-clickable-parts-of-a-shape), [going to shapes](#selection),
[rows read from more than their shape](#rows-read-from-more-than-their-shape), and the panel's
[text boxes](#text-of-a-plugins-own-detailtextbox) and
[sections a service shows](#contributing-two-points-and-their-sugar).

```swift
// In StickyNotesPlugin.register:
registrar.shape(StickyNoteDefinition()) { note in
    ...
    note.noteRow()                                               // its row reads its mention text (below)
    note.mentionText { $0.mentionTexts }                         // where its text, with pills, is drawn
    note.mentionable(untitled: { $0.props.text.firstLine }, tint: { _ in NoteStyle.tint })   // by its title, else its first line; yellow
}

// In SubboardsPlugin.register:
sub.mentionable(tint: { _ in SubboardStyle.border }, following: .opens)   // by its title; the card's indigo; followed, it's entered
```

### Mentionable kinds

A kind opts into being mentioned with `x.mentionable(label:untitled:symbol:detail:tint:following:)`, one per
kind (the `ShapeMentions` point; `registrar.mentionable(K.self, …)` from a bridge, and
`registrar.mentionableEveryShape(where:)` for a composition that wants every kind, which a kind's
own takes the place of). Every closure reads only the shape, as a title does, so a pill changes
only when its shape does:

- **Its name** is `label`, else the shape's title (Titles' `registry.title(of:)`, named or
  derived), else `untitled`, else "Untitled" and the kind's name ("Untitled Subboard"), each on one
  line, blank counting as none. A shape called by that placeholder has no name its kind gives it,
  so the `@` picker leaves it out until it has one; a mention of it shows it, live. A note that isn't titled is called by the first line of its text
  with words in it (`firstLine`), each mention there "@…" ("See @… first"): it names no other
  shape, live or as its mentions hold them. A mention holds its target's name as it was written,
  and an untitled note's name is its first line, so if its mentions' names were in it, two notes
  that mention each other would each take in the other's name, and their own with it, every time
  either was written.
- **Its symbol** is `symbol`, else its kind's (`registry.label(of:)`); `detail` is said beside the name in the
  picker (the kind's name by default), and `tint` colors the symbol where the surface is neutral:
  the picker, Mentioned In's lines, a pill in the panel's text. Give the kind the color its row
  has, so it reads as one kind everywhere (a note's yellow, a subboard's indigo); the panel's
  header keeps its symbol neutral.
- **Following one** (a double-click on its pill, Go to in the text's menu) is `following`:
  `.goesTo`, the default, goes to the shape (Selection's `goTo`: selects it and brings it into
  view); `.opens` goes into it (`goInto`: goes to it, then opens it, as a double-click on it would,
  one step back in all), for a kind that's opened rather than looked at: a subboard shows its
  board.
- **Its Mentioned In tab.** Opting in brings the kind's panel a tab listing what mentions each
  shape, shown only while something does ([What mentions a shape](#what-mentions-a-shape)), so a
  plugin list with a mentionable kind needs `DetailPanelPlugin()`. `mentionableEveryShape` brings
  none, since the panel has no section for every shape's record.

`registry.mentionAppearance(of:)` is how a shape shows (`MentionAppearance`), and
`registry.mentionResolution(of:lookup:)` what a mention of an id shows now (`MentionResolution`):
`.live` with its appearance, `.missing` for no such shape, or `.unavailable` for one kept aside,
whose kind can't be mentioned, or on a board the app can't show, which shows as missing. A shape on
another board of the file is live ([across boards](#mentions-across-boards)).

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
  (a note pasted into another file mentions a shape that isn't there, which shows as missing;
  pasted on another board of its own file, it names a shape that is, which shows live), and
  `canvas draw` makes a note that mentions a shape that isn't there, with a warning.
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
  Blockers.self)` or `registrar.mentionable(Subboard.self, in: Blockers.self)` (a kind must be
  mentionable to join, and the scope declared).

A scope limits what the picker offers, and the schema says it. It never refuses a mention that's
there (pasted, or written by an agent), as a bound is a guideline, though
[MentionValidation](#warnings-mentionvalidation) warns about it. No shipped text is restricted yet:
a note's text mentions any mentionable shape. MentionsTests hold scopes with
fixtures (a `Brief` holds text of `Only<Plate>` and of `Blockers`, which plates and tokens join).

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
- **Zoomed out**, a note is its [skeleton](#skeletons), bars where its lines are, and a render
  isn't asked: no mention text is drawn there, no string built and no pill laid out, and the memo,
  at the end of the first such frame, lets go of all but the 2,048 used last.
- **Where pills are.** `editor.mentionPills(of:)` is each pill's frame, in world units, with
  `isLive`, from the same placements, as string drawing puts them: a line that doesn't fit, or a
  pill the "…" of a cut-short last line covers, has none. The `MentionTexts` point (`x.mentionText`,
  `registrar.mentionText(K.self)` from a bridge, `registry.mentionTextPlacements(of:)`) is what the
  faces read.

### The service: `MentionState`

`MentionState` (`editor.mentions`) is what Mentions knows about a file, and never transacts (so it
follows undo and redo, during which nothing may):

- **Who mentions whom** is [Topology](#topology)'s: each mention is an edge of type `mention`
  (`MentionEdge`, a root), from the shape whose text holds it to the shape it names, in the slot of
  the property the text is in, counted once for each time the text names it. Mentions' source
  reads it out of mention text wherever a shape keeps it (a property, or a struct, list, set or
  dictionary in one: `forEachNamingLeaf`), on the kinds that can hold names
  (`registry.namingKinds`), and Topology keeps the index, both ways, for the whole file.
  `mentions(in:)` is what a shape mentions, in text order, each once; `mentioners(of:)` who
  mentions a shape, anywhere in the file: those on the board shown in document order, then those
  on other boards in the file's order (each board where its owner is, depth first).
- **How each mentioned shape shows now** (`resolve(_:)`) is Mentions': it resolves every shape
  mentioned anywhere in the file, and each commit costs what it changed: the mentioned shapes it
  touched (Topology's `touched`, and what it changed on other boards) are resolved again. A commit
  that only moved shapes costs nothing, and showing another board reads no mention text and
  resolves nothing. It asks Topology to catch up with a commit before reading it
  (`topology.catchUp`), in case it hears the commit first, and looks Topology's service up as it's
  made, so that one is made, and hears each commit, before it. Undo and redo are commits too, with
  exact change sets (`restoredStep`), so the state follows a step undone as any other: a rename
  undone gives every pill, row and editor its name back, and a deletion undone makes its pills
  live. A file or board put in place (`replaceFile`, `replaceDocument`) is read afresh, with
  nothing to undo.
- **The names mentions show, for another thread**: `labels` (`MentionLabels`, `Sendable`) is what
  `plainText` reads for every shape the file mentions, so `text.plainText { labels.label(of: $0) }`
  is `state.plainText(text)` anywhere (`label(of:)` is nil while a target is missing or
  unavailable, so the name the mention holds shows, and for a shape nothing mentions). Taking them
  costs nothing: they share what the state keeps, which its next change (a rename, a shape
  mentioned anew) copies once while they're held. They're as of the last commit the state heard (a
  rename after they're taken isn't in them): a query takes them as it takes up the file, and reads
  mention text with them off the main actor ([MentionQueries](#what-plugins-add)). MentionsTests'
  LabelsTests hold them to `plainText`, read on a detached task.
- **Following changes**: `observe(_:_:)` tells an AppKit view which of its targets' resolutions a
  commit changed (the text view's pills), `labelRevision(of:)` observes one target for SwiftUI, and
  `rowsAffected(by:)` names the shapes that mention what changed, for rows: a note's row reads its
  text with live names (`context.plainText(_:)`), and names `MentionRows.affected` as its
  `affected:`, so a rename remakes only the rows of the notes that mention the renamed shape.
- **The catalog**, what the picker searches: every mentionable shape on every board of the file
  the editor can show but those kept aside ([across boards](#mentions-across-boards)) and those
  its kind gives no name (called by the "Untitled …" placeholder: there's no point picking one; a
  mention of one stays, live), read again at the next query for the shapes a commit changed. `candidates(matching:in:for:)` lists, for an
  empty query, the recent picks (`didPick(_:)`) and the shapes nearest the text's shape on the
  board shown (looked for in squares around it, grown until one holds enough, or holds as many
  shapes as the board has in the catalog, when reading those costs less: a board with few
  mentionable shapes reads them), then, while there's room, the shapes whose boards it's inside,
  and for any other the best 50 matches. Every caret list's matcher (`CaretListMatcher`,
  DetailPanel's) scores the folded query (case and diacritics ignored) against each name, each
  taking its best tier: exact 1000, a prefix 800, each word a prefix of a word, in order, 600, a
  substring 400, a subsequence (fzf-style: word starts, runs and the first character count, gaps
  cost) at most 300, and, for a query of 4 or more that found fewer than 8 above, one typo (a
  Damerau edit of a word's prefix) 100; then recent picks and nearness (on the board shown) add to
  the best, and ties go to the shorter name, then the shape in front, the board shown's before
  another's. Two linear passes over the catalog's folded names and a heap: a keystroke at 10,000
  shapes, on one board or two (typed inside the subboard, the catalog the whole file's), and the
  `@` that opens the picker among 10,000 of which 3 can be mentioned, are held to 2 ms.
- **Going and hovering**: `follow(_:)` goes to a shape on the next turn of the scheduler
  (`editor.goTo`, or `goInto` for a kind followed by opening it: editing ends, the shape is selected and brought into view, and ⌘[ comes back;
  going is no undo step, so Undo after it takes back the edit before it, selecting what was
  selected then, and Back returns to where the mention went),
  since a click in the text being edited is still being handled by the view that going ends;
  `hover(_:)` and `endHover(_:)` set `editor.hovered`, so the shape is outlined faintly and its row
  tinted, the one hover every plugin shares.
- **What mentions each shape**, on any board, read from Topology's edges into it:
  `isMentioned(_:)`, `backlinks(of:)`, `backlinkRevision(of:)` and `showWhatMentions(_:)` ([What
  mentions a shape](#what-mentions-a-shape)).

### On the canvas: faces

A pill on the canvas is a [face](#faces-clickable-parts-of-a-shape): its shape's press, which
selects and drags the shape as any press does. Two planes, as text selection has them: the shape
is the note, and the text is its editor.

- **A click** on a pill edits its shape from the pill (`beginEditing(_:at:)` at the pill's
  center), and the editor selects the pill's character there: a pill is selected as text is, never
  followed on a single click. A read-only shape (a locked one) isn't asked to: a refused edit is a
  try to change it, which Locking shakes, and a click isn't one. A kind with no editing view is
  only selected.
- **A double-click** on an editable note's pill lands in the text view the click opened, which
  follows it. On a read-only shape, or one of a kind with no editing view, the canvas's face
  follows it (`goTo`, or `goInto` for a kind followed by opening it), and Back comes back. A missing pill's does nothing.
- **The pointer** over a live pill hovers the shape it names, if it's on the board shown; over a
  missing one, or one naming a shape on another board, its own shape.
- **None on a skeleton**: zoomed out, where the note shows no text, its pills are no faces
  ([Selection's rule](#faces-clickable-parts-of-a-shape)), so a click there selects the note, a
  double-click edits it (a locked one's shakes, going nowhere), and the pointer hovers the note.

Faces are Selection's, so a plugin list with Mentions needs `SelectionPlugin()` (and so
`KeyboardPlugin()`); Show What Mentions is an item in ContextMenus' menu, so it needs
`ContextMenusPlugin()` too (`ownerNotInstalled` otherwise).

### Editing: `MentionTextView`

The note's editor is a `MentionTextView<AnyMentionable>`, a `DetailTextView` (the panel's text
view, so the panel's boxes take it too: [In the panel](#in-the-panel-mentiontextarea)) on TextKit 2,
with the note's style, its shape as `owner` (never offered in its own picker) and the service. On
the canvas nothing of the panel's is set, so it's the text view it always was:

```swift
textView = MentionTextView(frame: CGRect(origin: .zero, size: frame.size), text: text, style: NoteStyle.text,
                           owner: context.shapeID, mentions: context.service(MentionState.self))
if let start = context.startPoint {                             // begun from a press: world units, the note at 0, 0
    textView.placeSelection(at: CGPoint(x: start.x - frame.minX, y: start.y - frame.minY), selectingWord: context.startClickCount >= 2)
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
  the pointer over it and hover the note. It's not a link: no pointing hand. Its menu adds Go to
  “Name” (a live one), Show What Mentions “Name” (a live one, unless the text is that shape's own
  and nothing else mentions it; on the scheduler's next turn, as Go to is) and Remove Mention,
  which leaves its name as text.
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
  Note"), or why it isn't live ("…, deleted"). Writing Tools leave pills alone.
- **The picker.** `@` typed where a word starts (at the start, after whitespace or an opening
  bracket or quote, never in `name@example.com`) opens it: `textView.picker`, a `MentionPicker`,
  the picker's model, headless, built on DetailPanel's caret list ([A list at the
  caret](#text-of-a-plugins-own-detailtextbox): its `CaretList`, shown in a `CaretListWindow`, a
  child window that never takes the keyboard, at the picker's own size). What's
  typed after the `@` is the query: Recent and Nearby for an empty one, else the matches, the
  matched characters semibold; "No matches" or "Nothing to mention" when there's none. ↑ and ↓
  move, Return and Tab pick, Escape (or ⌘.) closes, and so do the caret leaving the query, a line
  break, a query longer than 80 characters (a whole title can be typed), or a space after a query
  that matches nothing. A pick puts the pill in the query's place, then a space, one step of the text's
  undo, which gives back the query as typed. Undo while it's open closes it: the text's, taking
  back the `@` typed, or the board's, ending editing. While it's open, the highlighted shape is hovered on the canvas,
  and autocorrection is off. VoiceOver hears its list change as the highlight moves (the row, or
  the empty state, said) and go as it closes (`MentionAccessibility`, which the list's window
  posts through).
- **Where editing began.** `placeSelection(at:selectingWord:)` puts the selection where a press
  at a point in the view would (`selectPill(at:)` selects only a pill): the note calls it with
  `EditContext.startPoint`, so a click on a pill on the canvas has that pill selected in the
  editor, a click on a selected note's text puts the caret there, and a double-click on a word
  selects it (`startClickCount`, found with TextKit 2's selection navigation, so it works with no
  window). Begun with no point (Return, a placement), the caret goes where it always has.
- **Its delegate** is the view's own (`MentionTextDelegate`: it keeps pills out of what Writing
  Tools rewrite), which hands its host (the note's editor, a panel box) the rest of what a text
  view asks, but only the questions `HostlessTextDelegate` answers too: a text view reads what its
  delegate answers once, as it's set, and the host, held weakly, may be gone while the view still
  asks (a panel's box let go before its view leaves the window), when each question gets the answer
  a text view with no delegate gets. A host's delegate method outside that list isn't handed on
  until it's added there.

A note's render and its editor lay the pills out alike: each pill's frame in the editor is the
canvas's (StickyNotesTests' `noteEditorTests`), so nothing moves when editing starts.

### In the panel: `MentionTextArea`

Mention text edits in the detail panel as it does on its shape: `MentionTextArea`, a
[`DetailTextBox`](#text-of-a-plugins-own-detailtextbox) over a `MentionTextView`, in a section of
the kind's. No shipped kind puts one in its panel yet (a note's text is edited on the note);
MentionsTests' fixtures hold it, a jot's text and a brief's Blocked By:

```swift
DetailSection("Text", in: FieldsTab.self) { $jot in
    MentionTextArea($jot, \.text, placeholder: "Say something")   // height:, placeholder:, onCommit: as a DetailTextArea's
}
```

- **As on the canvas**: pills, the `@` picker, copy and paste, a click on a pill selecting it and a
  double-click going to its shape, Go to, Show What Mentions and Remove Mention in its menu. Its
  owner is the shape the binding writes (`$jot.shapeID`), never offered in its picker. The style
  is `MentionStyle.panelText`: the panel's font (`DetailStyle.textFont`), the label's color, and a
  neutral surface, where each pill's symbol takes its target's tint, as in the picker.
- **Writes.** It writes the field on every change, as the panel's text does: a run of writes is one
  undo step, named for its section ("Change Text"), a pick, Remove Mention and a paste included. A pick with the mouse is
  part of the run too: the picker is a child window of the board's, and a click there, unlike one
  in any other window that isn't a board's, doesn't seal the run ([Undo](#undo)). It shows what
  the shape says only when that changed from elsewhere (an undo of the board, another plugin's
  write), with `show(_:)`: its pills as their targets are now, the caret where it was, the picker
  closed, and nothing written back. A rename of what it mentions redraws its pills and writes
  nothing, as in a note being edited.
- **Keys.** Without `onCommit` (a jot's), Return is a new line; with it (a brief's), Return, ⌘↩
  and the keyboard leaving say the text is done, and ⇧↩ is a new line. While the picker is open its keys
  are the picker's (`holdsKeys`): Return and Tab pick and commit nothing, and Escape (or ⌘.)
  closes it; a second leaves the panel.
- **Read-only** (a locked shape, `detailUpdating`), it's dimmed as one, text and pills
  (`showEnabled`, by `alphaValue`), opens no picker (a lock landing closes an open one), and its
  menu has no Remove Mention; its clicks still land, so a click selects a pill, text is selected
  and copied, and a double-click on a pill still goes to its shape, which changes nothing; nor
  does it ever say its text is done (`onCommit`), since nothing was written.
- **Undo.** In a board's window, Edit › Undo while it has the keyboard is the text's own (a pick
  undone gives back its query), written back once; once the keyboard leaves, the board's Undo takes
  back the field's run whole, "Undo Change Text".

### What mentions a shape

Topology keeps each shape's edges both ways, so what mentions a shape is its `mention` edges in:
its backlinks, which cost what the shape's own edges do, never the board. They're the file's, as
the index is ([across boards](#mentions-across-boards)):

- **`isMentioned(_:)`**: whether another shape, on any board the editor can show, mentions it. A
  shape's mention of itself doesn't count.
- **`backlinks(of:)`**: a `MentionBacklink` per mentioner, in `mentioners(of:)`'s order (the board
  shown's in document order, then the other boards' in the file's), the shape itself left out.
  Each is named as it's mentioned (`mentionAppearance`), else by its title, else its kind's label,
  with its symbol, and carries a quote: about 60 characters (`MentionStyle.quoteLength`) of
  its text as plain text around its first mention of the shape, each mention "@" and the name it
  shows now, on one line, the mention whole and the rest shared half and half on each side (room
  one side doesn't use goes to the other), cut between words with "…" where text is left out. It
  reads each mentioner's record wherever it is, from the board shown and the file read without
  observing them (the core's `editor.withoutObservingDocument { … }`), so a SwiftUI view that
  reads it redraws only as its revision says; and it keeps no copy of the file, which would make
  the next commit that adds or removes shapes copy the file's table of where each shape is.
- **`backlinkRevision(of:)`** is observed per shape, as `labelRevision` is: it changes when a commit
  adds, changes or removes a shape that mentions the shape or did, on any board (never when it
  only moves one: a drag costs nothing), when a name a mentioner's quote shows changes, and on a
  switch of board, which puts that board's mentioners first. Topology says which shapes' mentions a
  commit changed (`touched(types:)`, so an arrow bound to a mentioned shape changes nothing
  here), and Mentions adds what each shape the commit added or changed, or
  touched on another board (`elsewhere`), mentions now, since an edit that keeps a mention changes
  its quote and no edge.
  Only shapes whose revision was read since it last changed tell observers, so a rename of a
  subboard 100 notes mention tells no one who isn't looking.
- **`showWhatMentions(_:)`** goes to what mentions the shapes (their mentioners, each one's
  mention of itself left out) and brings them into view (`editor.goTo`: one step back): the board
  shown's first, so it stays if any are there, else it shows the first one's board and selects
  those there; on the scheduler's next turn, since from a menu in text it ends the editing that
  menu's view is part of; nothing if nothing mentions them.

Two places show them:

- **The Mentioned In tab** (`MentionsTab`, order 300: a tab of the shape's state that comes and
  goes, as Issues is) comes with a kind's opt-in, `x.mentionable` or `registrar.mentionable(K.self)`.
  Its one section is shown while the shape `isMentioned` (`shownWhile`, asked on every commit, the
  shape's own edges), so the tab shows only then. A line per mentioner, its symbol, its name and its quote
  under it; the pointer on a line hovers the mentioner if it's on the board shown (`editor.hovered`:
  outlined on the canvas, its row tinted), and a click goes to it (`editor.goTo`, on the
  scheduler's next turn: its board shown first if it's on another; ⌘[ comes back). The list
  observes the shape's `backlinkRevision` alone, so a mentioner renamed, added or removed redraws it though the shape
  itself didn't change, and a drag redraws nothing. Its lines work on a read-only shape too
  (`enabledWhileReadOnly`): going to what mentions a locked shape changes nothing of it. In debug
  builds `MentionState.backlinksShown` records what each list last drew, for tests.
- **Show What Mentions**, in the canvas's context menu: an item for the canvas
  (`contextMenuForCanvas`, since whether a shape is mentioned is what Mentions' state knows, not
  the shape), in `MentionsMenuGroup` (order 50, after a kind's own items), shown when any shape the
  menu is for is mentioned, and in a pill's menu in text ("Show What Mentions “Name”"). Both run
  `showWhatMentions`.

So a list with a mentionable kind needs `DetailPanelPlugin()`, and one with Mentions
`ContextMenusPlugin()`; the report shows the tab as `ShapeDetails → sticky-note` after the kind's
`mentionable`, and the menu item as `CanvasContextMenu` on the `mentions` line.

### Warnings: MentionValidation

A mention that's there is never refused, as a scope never refuses one, but some can't work, and a
bridge between two horizontals says so:
[`MentionValidation`](../Sources/MentionValidation/MentionValidation.swift), which neither Mentions
nor Validation knows. Mentions finds the problems (`registry.mentionProblems(of:lookup:)`, each a
`MentionProblem`: the property the text is in, and a sentence), and the bridge makes each a warning
about that property:

```swift
registrar.validateEveryShape(ignoringMoves: true) { shape, context in
    guard context.registry.namingKinds.contains(shape.kind) else { return [] }   // no mention text: one set lookup
    return context.registry.mentionProblems(of: shape, lookup: context.shape).map { .warning($0.message, field: $0.property) }
}
```

| Problem | Warning |
|---|---|
| A mention of a shape whose kind can't be mentioned (an arrow) | `“Arrow” can’t be mentioned.`: named as the mention holds it, else by its kind |
| A mention of a mentionable shape outside its text's scope (scoped text only: `AnyMentionable` admits every one) | `“Groceries” can’t be mentioned here.`: named as it's called now |
| Text that looks like a mention but isn't one | `“@[x](shape: 7C1E…” isn’t a mention.`: quoted to 30 characters |

- **Never for a missing shape**: its dashed pill says so. Nor for one kept aside, which isn't the
  app's to judge, nor for a shape on another board: targets are looked up on the board shown
  (`context.shape`), the only board Validation checks, so one elsewhere is looked up no more than a
  missing one.
- **Each target once per text**, in text order, then the text's look-alikes; the same problem twice
  in one property is said once. Every text a shape keeps is walked (`forEachNamingValue`, then
  `forEachNamingLeaf`), so text in an added property warns about that property.
- **Look-alikes** (`text.lookalikes`): from each `@[` that isn't escaped and starts no mention, and
  has `(shape` (in any case) after it on its line before the next `@[`, through the first `)` after
  that, else to the line's end or that `@[`: `@[x](shape: 7C1E…)` (a space), `@[x](shape:1234)` (no
  UUID), `@[a]b](shape:…)` (a `]` not escaped). `\@[`, `@[x]` alone, and a mention with a lowercase
  id aren't. What an agent or a hand meant as a mention and got wrong: no surface writes one, since
  text made from runs escapes every `@[` in its text. Text with no more unescaped `@[`s than
  mentions has none, which one pass over its bytes tells, so asking costs little for text without.
- **Changes check again.** The lookups are Validation's, so a change to a target (renamed, deleted,
  undone) checks its mentioners again. The rule ignores moves, so a drag of a shape 100 notes
  mention, or of the whole board, runs it for none of them (`MentionValidationPlugin.textsChecked`,
  debug builds, counts the texts it checks, which tests hold a drag to).

Shipped after ValidationContents, its warnings show as any issue does: an orange outline, a line in
the Issues tab and a dot on the row.

### Mentions across boards

Shape ids are unique across a file ([Boards in a file](#boards-in-a-file)), so a mention names a
shape on any board of it, and shows it as it's called now, wherever it is:

- **Its pills are live.** `resolve(_:)` looks on the board shown, then in the file
  (`editor.shape(inFile:)`); the canvas draws a pill through `context.shape(inFile:)`, the core's
  lookup for a render that names shapes (read as the shape is drawn: a write to another board
  redraws the canvas, so a name drawn is never stale), and `editor.mentionPills(of:)` alike. A
  shape in no board of the file is missing, as `canvas draw` warns. So is one on a board the app
  can't show (`canShow`: its owner kept aside, of a kind that owns none, or not in the file), which
  the file keeps without the app using it: `resolve` calls it `.unavailable`, it's drawn by the
  name the text holds, dashed, it isn't followed, and `canvas draw` warns about it too.
- **Its name follows the shape**, whatever board is shown when it changes. A commit that reaches
  other boards names what it touched there (`ChangeSet.elsewhere`: the boards a deletion took with
  their owner, a paste brought, a write to a board that isn't shown, `transact(on:)`, or an undo
  put back), and `MentionState` resolves those it tracks again, telling observers, bumping their
  revisions, and naming the mentioners' rows. A rename made while the mentioning board wasn't shown
  leaves that board's revision as it was, so on going back to it the table of contents takes back
  its rows and hands `rowsAffected` what changed elsewhere meanwhile, and the rows of the notes
  that mention them are made again ([rows read from more than their
  shape](#rows-read-from-more-than-their-shape)); the pills, resolved as the rename landed, are
  already right. Undoing a rename made on another board shows that
  board first ([Undo](#undo)); on going back, the name is as it was.
- **A board deleted with its owner** takes its shapes' names with it: their pills show the name
  they hold, dashed, and undoing the deletion, which brings the boards back with every id, makes
  them live again.
- **Following one** goes there: a double-click on its pill (the canvas's face, or the text view's)
  or Go to “Name” runs `editor.goTo`, which shows the shape's board and selects it there as one
  step back (`showBoard(_:selecting:)`: Back returns to the board left, with what was selected
  there), then brings it into view. A kind followed by opening it (`following: .opens`) runs
  `editor.goInto` instead: a mention of a subboard enters its board, through the board it's on if
  that's another, and Back returns to where it was followed from in one step. Hovering one only
  outlines a shape on the board shown.
- **A copy of a tree of boards** mentions the copies of the shapes copied with it, on any board of
  the tree (Clipboard's paste passes names through the whole tree's map), and goes on naming the
  rest, wherever they are.
- **Moving by cut and paste keeps mentions.** Cut and paste is the way to move shapes to another
  board, and it's a move ([the clipboard](#the-clipboard)): a paste of what a cut took keeps each
  id the file doesn't use, so a mention from anywhere else in the file of a shape that moved shows
  it missing between the cut and the paste (by the name it holds), and live again once it's
  pasted, on whatever board, and following it goes there; what moved with it mentions it as before.
  Undoing the paste makes it missing again, and undoing the cut too, live where it was. A second
  paste of the same cut is copies, as a copy's paste always is. Only an arrow bound to what moved,
  from outside it, isn't kept: a binding lets go at the cut, as at a delete.
- **The picker lists the whole file.** Its catalog is every mentionable shape on every board the
  editor can show (the root, and from it down the boards of owners that aren't kept aside, of kinds
  that own boards: `canShow`'s), read whole as the editor opens, or a file or a board is put in
  place (`replaceFile`, `replaceDocument`), and kept up to date by each commit: the shapes it names
  on the board shown, and those it changed elsewhere (`ChangeSet.elsewhere`: a board deleted with
  its owner, a paste's boards, a write to a board that isn't shown, an undo that reaches another
  board), read again at the next query, so showing another board reads none of it. A match on the
  board shown gets nearness, and wins a tie; an empty `@` lists what's near the text on the board
  shown, then the boards it's inside (the board shown's owner first), so a subboard can be
  mentioned from inside itself. data-canvas's picker listed the board shown's shapes only.
- **Who mentions whom is the file's** (Topology's), as is what each mentioned shape shows: read as
  the editor opens, and kept up to date by every commit, whatever board it's on. So entering a
  board, even for the first time, reads no mention text, and `mentioners(of:)` lists a shape's
  mentioners on every board.
- **So are backlinks.** The Mentioned In tab and Show What Mentions list the mentioners on every
  board, the board shown's first; a line goes to its mentioner's board, and so does Show What
  Mentions when none is on the board shown.
- **But not warnings.** MentionValidation looks a mention's target up on the board shown, so a
  mention of a shape on another board is checked no more than a missing one is
  ([Not built yet](#not-built-yet) across boards).

MentionsTests' `boardsTests` hold these on pockets (and a mention of a shape on a board the app
can't show); CompositionTests' `mentionsBoardsTests` on
the shipped notes in a subboard (rows across switches, renames there and their undo, the subboard
deleted, a locked note's pill double-clicked, a subboard copied with the notes inside it and beside
it, one cut and pasted with every id kept, a note cut inside one and pasted on the root, and
`canvas draw` naming a note two boards down); `SubboardFileTests` a saved file whose
notes mention each other two boards apart (`nested-mentions-across.v4.json`).

## Topology

Topology ([`Sources/Topology`](../Sources/Topology)) is what connects and contains what, whatever
is where: edges, a typed graph (an arrow bound at both ends, a mention), and containment, a tree
(which board a shape is on, and so which shape it's inside). Spatial relations (a note that
happens to sit within a rectangle's bounds) aren't part of it; they're geometry. It's a horizontal
on the core alone: the plugins that own what a connection means (Ports, through its connector, and
Mentions) say what their shapes carry, and any plugin asks what's connected to a shape, and how,
without knowing arrows or mentions.

```swift
guard let topology = editor.topology else { return }                   // nil without TopologyPlugin
topology.neighbors(of: note)                                            // ["note-link": [a, b], "mention": [c]]
topology.edges(of: note, .incoming, types: .only(MentionEdge.id))       // who mentions it, anywhere in the file
topology.edges(ofType: .within(ArrowEdge.id))                           // every arrow bound at both ends, on any channel
topology.isInside(note, subboard)                                       // on its board, or on a board under it
```

### The shapes are the system of record

An edge is carried by a shape, its **carrier**: an arrow's record (its two bound ends, and its
channel, `added.channel`) is its edge, and a note's text is its mentions. Topology's index is
derived from the records, for the whole file, in memory, and never saved: nothing goes in props,
metadata or the file, so nothing can disagree with the shapes, and whatever already works on shapes
(undo, copy and paste, a deletion's cascade, migrations, `canvas draw`, a board from an older app)
works on edges with nothing more.

tldraw keeps bindings as records of their own beside the shapes (an arrow's binding to a shape is
a record from the arrow to the shape), which its store keeps in step with both. Here that would be
a second truth about each connection: records to copy, delete with either end, migrate and undo,
kept in step with the carrier they describe. And a mention outlives the shape it names, which a
binding can't. So the carrier holds a connection once ([Values that name
shapes](#values-that-name-shapes)), and the index is a way to read it.

### Edges

An `Edge` goes from `source` to `target`, of `type` (its most specific), carried by `carrier` in
`slot` ("" for the carrier itself, as an arrow is; else the name of the property that holds it, a
kind's own or an added property's key: a note's mentions are in `text`), `count` times there (a note
that mentions a shape twice: 2; an arrow: 1). Its identity is its carrier, slot, type and ends;
`count` is a value. Its ends needn't be there: a mention outlives what it names, so how an end is
now is asked when it's read (`end(_:)`, below).

Only a connection bound at both ends is an edge: an arrow with a free end carries none. A shape
kept aside (`record.isOpaque`) carries none, nor does a shape on a board the editor can't show.

### Types

- **An edge type is a type** (`EdgeType`: `static let id: EdgeTypeID`, and `static var parent`
  and `static var summary`, nil by default), declared by the plugin that owns what it means
  (`registrar.edgeType(T.self)`; the `EdgeTypes` point, one declaration per id: two are a
  `conflict`). The id audit holds an `EdgeTypeID` literal to the module that declares it, as it
  does a channel's.
- **Types are a tree.** Each is under at most one parent, which some installed plugin must declare,
  and none is under itself (`EdgeTypes.check`):

  ```
  EdgeTypes: more declares edge type spark under fire, which no installed plugin declares
  EdgeTypes: more declares edge type spark under itself: spark → flame → spark
  ```
- **Shipped:** `arrow` (`ArrowEdge`, ArrowPorts'), a plain arrow's type, and under it each channel's,
  `note-link` and `schema-link`; and `mention` (`MentionEdge`, Mentions'), a root. A channel is an
  edge type of the same name, which `registrar.channel(C.self)` declares with it
  ([Channels](#channels)), under the family the connector names (`connects(_:edgeType:…)`), so its
  parent follows from the registry as built: `registrar.edgeType(_:parent:)` is that form, the
  parent a closure over the frozen registry. `ArrowEdge.id` is `EdgeTypeID(rawValue:
  Arrow.kind.rawValue)`: the audit gives a string to every module that declares it, so a second
  declaration of `"arrow"` would have Arrows, which writes it, depend on ArrowPorts.
- **What a type means** is its `summary`: a lowercase line, no period, saying what it joins and
  which way it runs, which a [query's vocabulary](#queries) shows beside it
  (`EdgeTypeTree.summary(of:)`; `edgeType(_:parent:summary:)` carries one, and Ports' `Channel.summary`,
  nil by default, is passed on by `registrar.channel(C.self)` to the type it declares). Shipped:
  `arrow`, "an arrow bound at both ends, from the shape it starts on to the shape it ends on, whatever
  its arrowheads"; `note-link`, "an arrow drawn on the note-link channel", and `schema-link` likewise;
  `mention`, "a mention in a shape's text, from that shape to the shape it names".
- **An edge reports its most specific type**, and a query names types with an `EdgeTypeFilter`:
  `.all`; `.within(t, …)`, those types and every type under them (`.within(ArrowEdge.id)` is every
  arrow, plain or on a channel); `.only(t, …)`, exactly those (`.only(ArrowEdge.id)` is plain
  arrows alone). Each also takes a sequence (`.within(types)`, a query's resolved types), and an
  empty one admits nothing.
- **A type nobody declares** (an arrow's channel from a newer app, or from a plugin that isn't
  installed) is kept as written: it's the edge's type, `types.isDeclared(t)` is false, and it has no
  parent, so only `.all` and a filter that names it match it. A channel that names a type declared
  as something else (`mention`) is the connector's family instead, so no source's edges pass for
  another's.
- **The tree** is `registry.edgeTypes`, worked out on each call, or an editor's `topology.types`,
  kept (`EdgeTypeTree`: `declared`, in plugin order, `isDeclared(_:)`, `plugin(declaring:)`,
  `parent(of:)`, `children(of:)`, `ancestors(of:)`, parent first, and `descendants(of:)`).

### Sources

What a record carries is said by sources (the `EdgeSources` point), which add up: a kind's shapes
carry what each of its sources emits, in plugin order, with no precedence.

```swift
// A kind's own, typed:
x.edges { shape, registry, sink in … }
// A kind another plugin registers (a bridge's, or a horizontal's over a kind it's given):
registrar.edges(K.self) { record, registry, sink in … }
// Every kind `where` picks, asked once per kind:
registrar.edgesForEveryShape(where: { kind, registry in registry.namingKinds.contains(kind) }) { record, registry, sink in … }
// Every shape a value of an added property names, from the shape that holds it:
registrar.edges(in: BlockedByProperty.self, as: BlockedByEdge.self)
```

- **A source is pure** (`EdgeEmitter`): a function of one record and the frozen registry. It never
  reads other shapes, geometry, services, the camera or the time, and never depends on where a box
  is. That's what lets the index follow a commit by reading only the records it changed, skip those
  it only moved (`ChangeSet.moved`), and have undo put edges back exactly. Nothing checks it: a
  source that reads more goes stale.
- **`sink.emit(type, from:to:slot:)`** says one edge. Emitting the same type, ends and slot again
  counts it again; edges keep the order they were first emitted in (a text's order).
- **Ports' source** is the connector's: `connects(K.self, edgeType: F.self, …, ends:)` emits one
  edge for a connection `ends` finds bound at both ends, typed by its channel or, drawn on none, by
  `F` ([ArrowPorts](#the-connector-arrowports)). **Mentions'** is over the kinds that can hold
  names: each mention in mention text wherever a shape keeps it (`record.forEachNamingValue(in:)`,
  then `forEachNamingLeaf`), in the slot of the property it's in.
- **The property rule**, `registrar.edges(in: P.self, as: T.self)` for an added property whose
  value names shapes (`P.Value: ShapeNaming`), is for a relation nobody draws or writes in text
  (what a task is blocked by): every shape a value of `P` names is an edge of type `T` from the
  shape that holds it, in the slot `P`'s key names, on every kind that opts into `P`. It doesn't
  declare `T`: `edgeType` does. Nothing shipped uses it yet.
- **`registry.edges(of: record)`** is what one record carries, as its kind's sources say, pure: for
  code that holds a record the index doesn't (a transaction's), and for tests.

The registry's report shows `edge type mention` on the declarer's line, and `edges → every shape`
or `edges → arrow` on the line of the plugin that contributes the source ([The
registry](#the-registry)).

### The index: `TopologyIndex`

`editor.topology` (nil without `TopologyPlugin`) is the file's edges, one index per editor, by
carrier, by each end and by type. It never transacts, and isn't an undo participant: it follows the
file. Every query costs what it returns, never a board:

| Query | Is |
|---|---|
| `edges(of: id, direction, types:)` | Every edge touching a shape, anywhere in the file: `.outgoing`, `.incoming` or `.either` (the default), of the types the filter admits (`.all` by default). By carrier, in the order the carriers came (those read as the editor opened in the file's order, root first; those one commit brings, a paste's or an undo's, in no order among themselves), each carrier's in the order it emits them. An edge from a shape to itself is there once. `hasEdges(of:_:types:where:)` stops at the first (that `where` takes), and makes nothing: cheap enough for what's asked on every commit (Mentions' `isMentioned`). |
| `neighbors(of: id, direction, types:)` | The shapes at the other ends, by each edge's type, each once per type, in the order its first edge comes: what's connected to a shape, and how. The shape itself, for an edge from it to itself. |
| `edges(ofType: filter)` | Every edge in the file of the types the filter admits: type by type (declared ones in plugin order, then the rest by name), each by carrier. |
| `edges(carriedBy: carrier)` | What a shape carries, in the order it emits them. |
| `end(id)` | How a shape at an end of an edge is now (`EdgeEnd`): `.live(board)` on a board the editor can show, `.unavailable` in the file on a board it can't (under an owner kept aside), `.missing` in no board of the file. |
| `revision(of: id)`, `touched` | A shape's revision, +1 each time its edges (at either end) change, from the first time it's read: reading it observes only that shape (a key path per shape, as Mentions' `labelRevision`), so a SwiftUI view of one shape's connections redraws when they change. `touched` is the shapes whose edges the last commit changed (none after a switch of board), and `touched(types:)` those whose edges of some types it changed (Mentions reads its own). |

### Containment

The board tree read as containment, the same for every kind that owns boards: `parent(of:)` is the
owner of the board a shape is on (nil on the root), `children(of:)` the shapes on the board it owns,
in document order, `ancestors(of:)` those it's inside, the nearest first, and `isInside(a, b)`
whether `a` is inside `b` at any depth (never inside itself; O(`a`'s depth)). It needs no index: the
core knows where every shape is. As with edges, only shapes on boards the editor can show count
(nil, none, or false for the rest). It's one piece of code, `Containment`, a value over a
`CanvasFile` and the kinds that own boards, which the index makes over the file as it is for each
question and a [snapshot](#a-snapshot-for-other-threads) keeps over the file as it was taken, so the
two answer alike. `containerKinds` (on `Registry`, the index and the snapshot) is which kinds
contain others: today the kinds that own boards. Containers that aren't boards (frames, groups)
would join them there, each a source of containment, a point Topology doesn't have yet, and every
reader, live or not, would follow.

### A snapshot for other threads

`topology.snapshot()` is Topology as it is now, for any thread: a `TopologySnapshot`, `Sendable`,
taken in O(1), reading no record and observing nothing. It shares the index's tables (its edges as
a value) and the editor's file (read without observing it), with the edge types, and answers
through the same code the index does, the tables and `Containment`, so what it answers is what the
index would have answered as it was taken: every question about edges and containment, though not
what changed (no `revision(of:)` or `touched`). A query takes one as it takes up the file and reads
it off the main actor, uninterrupted, whatever commits land meanwhile ([Queries](#queries)).

```swift
let graph = topology.snapshot()                                         // on the main actor, O(1)
Task.detached {
    graph.forEachShape { record, board in … }                          // every shape the app can show, in file order
    graph.neighbors(of: note, .outgoing, types: .within(ArrowEdge.id))  // as the index would have answered
}
```

Beside the index's questions, it reads the file whole:

- **`forEachShape(inFileOrder:)`**: every shape on a board the app can show, kept-aside ones too,
  with its board, in file order: the root's shapes back to front, each shape that owns a board
  followed at once by that board's shapes, and theirs, before the next. It's iterative, so a chain of
  boards of any depth is walked, and no board twice. An error its body throws stops it, and comes out
  as the body's own type (`throws(E)`: a query's cancellation is a `QueryError`).
- **`fileOrderKey(of:)`**: where a shape comes in that order, as a key that sorts lexicographically
  (the index of each owner above it on its board, from the root's down, then its own); nil off the
  boards the app can show. O(its depth): for putting a few shapes in order without walking the file.
- **`topLevel`**, the root's shapes in document order, and **`descendants(of:)`**, every shape inside
  a shape at any depth, in file order (O(what's inside it)).
- **`shape(_:)`**, a record on a board the app can show, kept aside or not (`isOpaque` tells), nil
  elsewhere (O(its depth)); **`presentTypes`**, the types of the edges the file has, declared or
  not; and **`end(_:)`**, as the index's.

**Hold one for a task, never past it.** Nothing is copied while it's held until a commit changes a
table it shares; that commit copies the table, once (a move changes none of the index's; a shape
added or removed copies the file's `locations`). Kept, a snapshot makes every later commit's first
change to a table copy it. And one taken by a service hearing a commit before Topology has is that
commit's file with the commit before's edges, as the index's own answers are then: `catchUp` first.
TopologyTests' Snapshots suite holds a snapshot to the index on every question, over a seeded run of
every kind of commit, switch and undo, and a snapshot taken a step before to its old answers.

### What it costs

- **As the editor opens**, every board it can show is read (the root, then down through the owners
  of boards it can show, as `canShow` has it: `registry.ownsShowableBoard`), each record's sources
  asked; a kind with none costs a lookup. A file or a board put in place (`replaceFile`,
  `replaceDocument`) is read again, and only the carriers whose edges changed touch anything.
- **Each commit** costs what it changed: the records it removed, touched on other boards
  (`ChangeSet.elsewhere`: the boards a deletion took or a paste brought, a write to a board that
  isn't shown), added, or changed other than by moving, each read again from the file as it is now
  (a shape on no board the editor can show carries nothing). Undo and redo are commits like any
  other. Showing another board reads nothing: the index is the file's (`boardDidChange` does
  nothing but for a file put in place).
- **Heard first.** A service that reads the index as it hears a commit must find it up to date.
  The shipped list has `TopologyPlugin()` right after `SelectionPlugin()`, so its service is made,
  and hears each commit, before those that read it; one that may hear a commit first calls
  `topology.catchUp(changes)` with the commit it holds, which does nothing once the index has heard
  it (MentionState does, and looks up `editor.topology` as it's made, so Topology's service is made
  first).
- **Held.** `./build.sh bench`: Topology's index and Mentions' catalog of 10,000 shapes, built as
  the file opens, within 50 ms (the budget Mentions' own index had); `neighbors(of:)` of a shape
  with 100 edges within 1 ms; and a drag's input, a subboard of 10,000 deleted in a frame, and its
  undo in 100 ms, with Topology hearing them. `recordsRead` (debug builds) counts the records
  sources read, so tests hold a commit to what it changed.

Every plugin list with a plugin that contributes to Topology's points (Ports, Mentions) needs
`TopologyPlugin()`, as one with Selection needs `KeyboardPlugin()`: a contribution to a point whose
owner isn't installed is `ownerNotInstalled`.

### What it doesn't do

- **Loose edges.** An arrow with a free end isn't an edge; there's no query for connections
  half-made.
- **Spatial relations.** A shape that happens to lie within another's bounds isn't inside it;
  that's geometry (`editor.paintOrder(in:)`, `shapeContext.bounds(of:)`).
- **Drawing by type.** Agents read the graph with [`canvas query`](#query), through a snapshot
  (`:edge-to`, `:downstream-of`, `"Payments" *`), but `canvas draw` matches an edge it restates by
  its ends, not by its type.
- **Showing it.** Nothing in the app shows a shape's connections in general yet (a Connections
  section of its panel); what mentions a shape is shown, Mentions' Mentioned In tab and Show What
  Mentions.

## Queries

Queries ([`Sources/Queries`](../Sources/Queries)) finds the shapes of a file a query matches: a
selector in a CSS-like language over every shape on every board the app can show, by kind, title,
id, attributes typed by their kind's schema, text, Topology's containment and typed edges, and the
words plugins add. It's a horizontal on Topology, over the core and QueryLanguage (DrawScript lends
it only its "did you mean", `Suggestions`), knows no plugin, and hears no commit. Agents ask through [`canvas query`](#query); any plugin may ask too:

```swift
guard let queries = editor.queries else { return }                 // nil without QueriesPlugin
let result = try await queries.run(QueryRequest(#""Payments" sticky-note:mentions("Auth")"#, limit: 20))
result.count                                                        // every shape that matches, listed or not
result.rows                                                         // the first 20, in file order
```

The language, every form, word and refusal, is taught to agents by the canvas skill
([`reference/query.md`](../.claude/skills/canvas/reference/query.md), whose every block SkillTests
runs on a file of its own, so it can't drift from the app). What a plugin needs of it:

- **A query** is a list of selectors, commas between them, each of compounds joined by a space
  (inside, at any depth) or `>` (on the board of); a compound is at most one head (a kind, `*`, a
  title in quotes, a kind with a title right after it, `sticky-note"Checkout"`, as CSS writes
  `div#id`, or `#` and an id) and then tests with no space between them, attributes in brackets
  and `:word`s: `"Payments" sticky-note[text*="retry" i]:mentions("Auth")`. A selector answers with
  the shapes its last compound matches, as in CSS, and a list with those any of its selectors does,
  each once.
- **QueryLanguage** ([`Sources/QueryLanguage`](../Sources/QueryLanguage)), a foundation module that
  knows no canvas, registry or plugin, reads it: `SelectorList(parsing:)`, a tree whose every part
  knows its place in the text (`QuerySpan`, in characters of the query as sent), and `canonical`,
  the one form it prints (its own words in lowercase, titles in double quotes, one space around `>`,
  no comments), which is what an answer says ran. It refuses what the text alone shows
  (`empty_query`, `syntax`, `stray_space`, `too_long`, `too_complex`, `unsupported`, `not_built`
  for `.Class` and `[a.b]`, `not_an_id`, and `bad_argument` for its own words), stopping at the
  first, and knows only its own words (`Word`: `:not`,
  `:is`, `:where`, `:has`, `:inside`, `:top-level`, `:current-board`, the edge words, `:dangling`,
  `:contains`); another's argument it keeps as text for the engine to read as shapes
  (`SelectorList(argumentOf:)`, its spans in the whole query), or to refuse with the rewrite for a
  word people invent (`KnownInventions`: `:parent-of`, `:near`, `:source-of`, and `:neighbor-of`,
  the language's old name for `:connected-to`). `QueryLimits` bounds it: 8,192 characters, 1,024
  in a string, 32 levels of parentheses, 256 compounds, 20 problems said.
- **Queries resolves it** against what this app has (`queries.check(_:)`, into a `QueryPlan`,
  `Sendable`, whose `description` prints it as a tree), refusing what isn't there with the one like
  it (`unknown_kind`, `unknown_attribute`, `unknown_pseudo_class`, `unknown_edge_type`,
  `invalid_value`, `unsupported_operator`, `cannot_contain`, `no_names`; `not_built` for an
  attribute that holds a place and `=` on an object; and the words people write in brackets,
  `[kind=…]`, `[id=…]`, `[board=…]`, with what to write), every problem that doesn't hang on another
  at once, in the query's order; and answers it, refusing a title or an id no shape has
  (`unknown_title`, `unknown_id`) rather than answering none. Nothing unknown is passed over: a
  query that runs asked what it says, and a hint is most often the query to write instead. A hint
  that is a query is never one the app would refuse for a reason the query it mends didn't have:
  one that takes for granted what only the app can say (that a title is some shape's, that a
  kind's shapes can have titles, that what it puts where a container goes holds a board) waits for
  it (`HintPremise`, QueryLanguage's, settled by the kinds and ids as the query resolves and by the
  titles as it's answered: `#Checkout` hints `"Checkout"` only where a shape is titled so).

### What a query sees

- **Every shape on every board the app can show** (`canShow`'s), none kept aside: a kept-aside
  shape has no properties to read and carries no edges, and a board the app can't show is the
  file's, not the app's. `#` with such a shape's id is refused `unknown_id`, saying which it is.
- **File order**, for every answer: the root's shapes back to front, each shape that owns a board
  followed at once by that board's shapes, all the way down, the order Topology's snapshot walks in
  (`forEachShape(inFileOrder:)`, or `fileOrderKey(of:)` for a few shapes), so the engine never walks
  boards itself. The same query on the same file answers in the same order. Both are Topology's, so
  without `TopologyPlugin` every query is `no_topology`.
- **One instant, but for what only the main actor knows.** An answer is the file as it was when the
  app took up the query, but for titles a shape works out from what it holds (a schema card's) and
  validity (`:invalid`, `:warned`), which are as the app has them when the query asks: a shape a
  commit changed while the query ran can answer with its newer title or verdict, never an older one,
  and one gone since has no title and fails the word. So no main-actor code is ever handed a record
  the app has since replaced, and no plugin's cache keeps one. The board shown (`:current-board`) and
  what's selected (`:selected`) are as they were when it started.
- **Titles through the names point** (Titles', through TitleQueries). A head `"Checkout"` is every
  shape whose title, folded as Titles folds one, is the literal folded, case and all, named or
  derived; several shapes may share it, and it names them all. A title no shape has is refused, so
  a no always means the shape is there: `[title="X"]`, which folds its literal the same way, is how
  to ask whether one is, its count of 0 an answer (warned `no_title_match`). A kind with a title
  right after it, `sticky-note"Checkout"`, is the kind's shapes with that title: a title head
  beside the kind's (the title's node first, as it finds its shapes), so a title no shape has is
  refused as `"Checkout"` is, one only other kinds have answers none, and a kind whose shapes have
  no titles is `unknown_attribute`, as `[title=…]` on it is. With a space between, the title is
  inside the kind's shapes, and where they hold no board the refusal (`cannot_contain`) hints the
  two together, if they can have titles. Without a names point, a title is `no_names`.
- **Attributes through the kinds' schemas** (`registry.schema(for:)`, read with
  [`KindSchema`](#a-kinds-schema)): every property, own or added, but those that hold a place (where
  a shape is isn't in the language yet: `frame`, `not_built`), and the names point's word (`title`),
  read through the names point, so a derived title is an attribute too, on the kinds whose shapes
  have titles. A literal is read by its property's schema as `draw` reads a value, and the test is
  typed by it: a number numerically (`[rank=3]` and `[rank="3"]` alike; one that isn't finite
  matches no number test), a date-time by its UTC day (`[due<2026-10-01]`) or instant, a choice from
  its list (`i`: in any case), a list by its items (`~=`), text as text (`^=`, `$=`, `*=`, `|=`, and
  `i` for any case; `<` refused). An absent true|false is its schema's default, else false
  (`[locked=false]` is every unlocked shape); `[a]` is a value that says something (true, text, a
  list or an object not empty, a number or a date there); `[a=""]` on text (mention text, a choice,
  a date, the names point's word too) is no value, absent or empty (`sticky-note[title=""]` is the
  untitled notes, since a blank title is none; `arrow[channel=""]` a plain arrow), and elsewhere
  `""` is what it always was; `[a!=v]` is `:not([a=v])`; and any other test of an absent value is
  false. With no kind named, a test applies to the kinds that have the attribute, each reading the
  literal its own way. `[a.b]` and `=` on an object are `not_built`, and a shape's metadata
  (`ShapeMeta`) is never an attribute.
- **Text as a person reads it.** A string whose schema names a media type a text format reads
  (`contentMediaType`) is tested and shown as that format makes it: mention text as plain text, each
  mention `@` and the name its target has now, or the name it holds while its target is gone, never
  the stored form with its ids. `:contains("x")` is a substring of the title or of any string in the
  attributes, as they read, in any case: a filter, not search.
- **Boards named as Boards names them.** A row's `inside` is the names of the boards it's inside,
  outermost first, as the path over the canvas names them: the owner's title, else its kind's
  placeholder (through the board names point), else its label.
- **A query changes nothing**: no shape, no selection, no step of undo. It never ends typing: a
  shape being typed into reads as the board has it (a note writes each keystroke, so its text as
  typed so far), and an answer that lists it, or read its text, warns that it may still change
  (`editing`).

`run(QueryRequest(text, limit:, countOnly:, properties:))` answers a `QueryResult`: `query` (the
plan's `canonical`), `count` (every shape that matches, listed or not), `rows` (the first `limit`,
`QueryBudget.rows` (100) unless it says, at most `maxRows` (10,000), in file order; none with
`countOnly`), `warnings` (`limited`, `editing`, `no_title_match`; `QueryWarning.Reason` is open,
and the command line adds `repaired`), `shown` and `shownPath` (the board the window showed as it
took up the file, `:current-board`'s, and the boards from the root down to it: where it ran, which
the command line's `board` says), and `timings` (thread CPU on the main actor and off it, the
slices, the longest, and the costliest record: the longest stretch between two reads of a slice's
clock, the stretch after its last read included). A `QueryRow` is the shape's `id`, `kind`,
`title` (nil for none), `board`, `inside`, `properties` (its attributes as they read: own properties
as a board writes them, added ones when set, text through its format, cut at `QueryBudget.cut` (500)
characters unless `.only([…])` names it, those cut named in `cut`; never where it is, nor its name;
none for `.none`), `connection`, for a shape that carries an edge itself in slot `""` (an arrow: the
edge's type and the shapes it runs `from` and `to`, each by id and title), and `editing`; it encodes
itself leaving out what's absent. `titles(for:limit:)` and `whereThePersonIs(selectedLimit:)` are
what [`--ask`](#--ask) sends the model, each run as a query is.

### Where it runs

A query costs the main actor what it reads and one turn, and does everything else off it:

1. **Checked**, on the main actor (`check`): parsed and resolved against the vocabulary
   (`queries.vocabulary`, a `QueryVocabulary`, `Sendable`: each kind with its label, how its shapes
   are named, whether it holds a board and what an untitled one's board is called, and its
   attributes with what each takes; the edge types in the tree's order, with their summaries; the
   words, the language's then plugins', each with its form, what it takes, what it means and an
   example; and `text`, the `<vocabulary>` block `--ask` sends: the kinds, the edge types and the
   plugins' words, since the prompt teaches the language's own), made on the editor's first query
   and kept, since the registry never changes.
2. **Taken up**, in one main-actor turn, in O(1) (`QuerySnapshot`): the file
   (`withoutObservingDocument { editor.file }`) and Topology's snapshot, shared and not copied; the
   board shown and the path to it; the revision and the shape being typed into; then what each word
   and text format the query uses takes (`prepare`, in word order: the selection's ids, Mentions'
   labels), every text format's when rows list attributes.
3. **Answered off the main actor**, in a task of its own (`Evaluation`), handed the snapshot whole
   (`Handover`), so the evaluation is its last holder and it's freed there, with everything read from
   it. A set at a time: each node of the plan is worked out once into the set of shapes it matches
   among the candidates its compound has narrowed to so far, and kept for the query, so nothing
   recurses per shape; a compound's tests run cheapest first (ids, titles and seeds; kinds; the top
   board and the board shown; containment and edges; attributes and text; words asked of the main
   actor last, on what's left).
   A compound with a one-step edge word (`:edge-to`, `:edge-from`, `:connected-to`, `:starts-at`,
   `:ends-at`, `:between`, a plugin's relation) and fewer than `QueryBudget.seedFromAnchors` (1,024)
   anchors starts from their edges' far ends, never a walk of every shape: `sticky-note:edge-to(#…)`
   costs the anchor's degree. Containment walks up from each candidate (its ancestors, worked out once
   per board), or, when nothing narrowed the candidates, down from the containers, asking only the
   shapes of `containerKinds` for their boards; transitive words go breadth first from their anchors.
   Titles and ids are checked here, against the snapshot (`unknown_title` with the titles like it,
   and, for a title standing for an edge word's or a relation's anchor where an edge of the types it
   follows points at a shape the query can't see from a carrier it can, the `:dangling` that finds
   those carriers, of exactly those types: `:mentions("Old ledger")` hints `:dangling(mention)`;
   `unknown_id`, `cannot_contain` for a title that names only shapes holding no board). The rows are
   made here too, in file order: the walk's, when every shape was walked, else `fileOrderKey`'s; a
   count isn't put in order at all.
4. **Asked of the main actor in slices**, for what only it can say: a derived name (the names point's
   `derived`) and a word's verdict (its `onMain`). `MainFacts` asks them in slices, each a
   main-actor job of its own that lasts `QueryBudget.slice` (2 ms of the thread's CPU) and at most the
   one record that crosses it, one record at least: its clock is read after the first record, then
   every `clockStride` (16) while the pace leaves room before `everyRecordAfter` (1.5 ms), and after
   every record from then on. The evaluation asks for the next slice only once it has the last one's
   answers, so a query never has more than one waiting on the main queue, and input, drawing and
   commits run between them (the main run loop services its sources between one job and the next).
   Each shape is asked about as the app has it when its slice runs: its id looked up in the live
   file, with the board it's on now (`QueryMainContext.shape(_:)`); one gone since, kept aside, or on
   a board the app can't show has no name and fails the word.
5. **Written** as the wire's JSON member by member, off the main actor too, where the result is let
   go of ([query](#query)).

**One at a time, and bounded.** Queries on one editor run one at a time, each taking up the file once
the one before it is done (`--ask`'s titles and where the person is too), so no two snapshots are
held at once. A query stops when its caller's task is cancelled (`cancelled`: the evaluation looks
every `QueryBudget.cancellationStride` (256) shapes and before each slice, and `canvas` hanging up
cancels the command's task); when `QueryBudget.deadline` (8 s, before `canvas`'s 10 s wait runs
out) has passed since it was asked, running or waiting its turn (`too_slow`: a scheduled action on
`editor.scheduler` cancels it, and is cancelled if the query ends first, so tests reach it by
advancing a `ManualScheduler`); and when its editor goes (`board_closed`: `QueryState` and
`MainFacts` hold the editor weakly, so a query never keeps a closed file's editor alive).

**Zero upkeep.** `QueryState` keeps nothing per shape or per board, implements no
`documentDidChange`, and overrides `boardDidChange` with nothing: a commit, a drag event's included,
and a switch of board cost queries nothing, ever, and nothing outlives a query but the vocabulary
(`liveSnapshots`, debug builds, is 0 whenever none runs).

**What a held snapshot costs.** While a query runs, its snapshot shares the file's tables and
Topology's, so a commit that lands meanwhile copies each table it changes, once: a drag event the
file's `revisions` (and, off the root, its `children`), a shape added or removed its `locations`, a
change of edges the index's tables it touches, a rename of a mentioned shape Mentions' resolutions
(while a text format holds the labels). At most one copy per table per query, and none once the
answer is made, since the snapshot is let go of then; `./build.sh bench` can't tell a commit with a
snapshot held from one without (below).

### What plugins add

Queries knows no plugin: what shapes are called, what an untitled owner's board is called, words
beyond the language's, how text of a media type reads, and what's selected come through points
Queries declares ([QueryPoints.swift](../Sources/Queries/QueryPoints.swift)), each filled by a
bridge between Queries and the plugin that owns the concern. Without one, a query does without:

| Point | Sugar | What a query gets | Without it | Shipped |
|---|---|---|---|---|
| `QueryNames` | `registrar.queryNames(attribute:source:named:derived:fold:)` | The attribute names are tested by; per kind, whether its shapes are named, derived or neither; a named shape's name, read anywhere; a derived one's, on the main actor; how a title a query writes is folded | No titles: a title head is `no_names`, and rows have none | TitleQueries |
| `QueryBoardNames` | `registrar.queryBoardNames(placeholder:)` | What an untitled owner's board is called, per kind | Its kind's label | BoardQueries |
| `QueryWords` | `registrar.queryPseudoClass(_:_:example:prepare:seeds:matches:onMain:)`, `querySelection(_:_:example:selected:)`, `queryRelation(_:_:example:types:direction:)` | A word: a pseudo-class, the person's selection, or a relation over edges of exactly some types | The word is `unknown_pseudo_class` | MentionQueries, ValidationQueries, SelectionQueries |
| `QueryTextFormats` | `registrar.queryTextFormat(mediaType:describes:prepare:read:)` | How strings of a `contentMediaType` read, anywhere | Text read as stored | MentionQueries |
| `QueryEngines` | none: `QueriesPlugin`'s mark, which only Queries makes | That the app answers queries (`registry.answersQueries`), for what has a registry and no editor | `canvas query` and `query-vocabulary` answer `no_queries` | QueriesPlugin |

`QueryNames` and `QueryBoardNames` take one contribution each, `QueryWords` one a word and
`QueryTextFormats` one a media type (their report lines: `query names`, `query board names`, `query
word :mentions`, `query text text/x-canvas-mentions`; `query engine` on queries'). The five bridges'
registrations, whole (each bridge's words are its own nested `enum Word: String`, and
ValidationQueries registers each of its two in a helper, whose `has` is below)
([TitleQueries.swift](../Sources/TitleQueries/TitleQueries.swift),
[BoardQueries.swift](../Sources/BoardQueries/BoardQueries.swift),
[MentionQueries.swift](../Sources/MentionQueries/MentionQueries.swift),
[ValidationQueries.swift](../Sources/ValidationQueries/ValidationQueries.swift),
[SelectionQueries.swift](../Sources/SelectionQueries/SelectionQueries.swift)):

```swift
// TitleQueries: a shape is called what Titles calls it; a named title read off the record anywhere,
// a derived one on the main actor.
registrar.queryNames(attribute: TitleProperty.key.rawValue,
                     source: { kind, registry in
                         if registry.titleIsDerived(kind) { return .derived }
                         return registry.properties(for: kind).contains(TitleProperty.key) ? .named : .none
                     },
                     named: { TitleProperty.folded($0[TitleProperty.self]) },
                     derived: { record, registry in registry.title(of: record) },
                     fold: { TitleProperty.folded($0) })

// BoardQueries: an untitled owner's board is called what the path calls it.
registrar.queryBoardNames { kind, registry in registry.boardPlaceholder(of: kind) }

// MentionQueries: Topology's mention edges as two words, and mention text as a person reads it.
registrar.queryRelation(Word.mentions.rawValue, "its text mentions a shape S matches", example: #":mentions("Checkout")"#,
                        types: [MentionEdge.id], direction: .outgoing)
registrar.queryRelation(Word.mentionedBy.rawValue, "a shape S matches mentions it", example: #":mentioned-by("API gateway")"#,
                        types: [MentionEdge.id], direction: .incoming)
registrar.queryTextFormat(mediaType: MentionTextFormat.mediaType, describes: "mentions read as @Name",
                          prepare: { $0.editor.mentions?.labels ?? MentionLabels() },
                          read: { stored, labels in MentionText(stored: stored).plainText { labels.label(of: $0) } })

// ValidationQueries: :invalid and :warned, which only the main actor can say.
registrar.queryPseudoClass(word.rawValue, summary, example: ":\(word.rawValue)",
                           prepare: { _ in () },
                           matches: { _, _ in .onMain },
                           onMain: { record, board, _, context in has(severity, record, on: board, context) })

// SelectionQueries: the person's selection, as the query takes up the file.
registrar.querySelection(Word.selected.rawValue, "the person has it selected", example: ":selected") { $0.selectedShapeIDs }
```

- **Names are titles.** A kind's shapes are `.named` when it opts into the title Titles keeps
  (`TitleProperty`), read off the record on any thread; `.derived` when Titles works them out (a
  schema card's, from its schema's `"title"`), read through `registry.title(of:)` in slices, which
  wins for a kind that's both, since Titles falls back to it for the shapes nobody named and only
  the main actor can say which; else `.none`. `source` is asked once per kind, as the vocabulary is
  made. The attribute must be a word a query writes bare (`QueryNames.check`), and `[title="X"]`
  folds its literal through `fold`, so it matches exactly what the head `"X"` does. The rule is
  `draw`'s own ([TitleNames](#what-draw-takes-from-other-plugins)), so the two name shapes alike.
- **Boards are named by Boards' rule**: the owner's name, else `placeholder` for its kind (asked once
  per kind), else its label (`registry.label(of:)`). BoardQueries' is `registry.boardPlaceholder(of:)`,
  which [`editor.name(of:root:)`](#boards) reads, so a row's `inside` says what the path's crumbs say.
- **A pseudo-class** (`:invalid`) takes no argument. `prepare` runs on the main actor in the turn the
  query takes up the file, taking what it needs there, O(1) or O(what it holds) (a set of ids, a
  service's value), and what it returns (any `Sendable`) is handed as it was to the rest: `seeds`, if
  given, the only shapes that can match, which a compound then starts from; `matches`, anywhere,
  `.yes`, `.no` or `.onMain` for each shape the query tests (a `QueryShape`: its record, its board and
  the Topology snapshot); and `onMain`, in slices, for those `matches` leaves to the main actor, about
  the shape as the app has it then, with a `QueryMainContext` (the registry, the editor, the revision
  as the query started, `shape(_:)`, and `shapes(on:)`, a board as the app has it now, one
  `ShapeContext` per board per query, made again once that board's revision changes). A word is
  lowercase words joined by hyphens, and never one of the language's own or one it refuses as
  invented (`QueryWords.check`).
- **The person's selection** is a pseudo-class of one sort: `querySelection` takes the shapes
  selected, in the selection's order, as the query takes up the file (so a change of the selection
  while a query runs changes nothing it answers), seeds and matches them, and is what `--ask` tells
  the model is selected (`whereThePersonIs`), in that order. At most one plugin says what's
  selected (`QueryWords.check`).
- **A relation** (`:mentions(S)`) is `:edge-to(S, only t)` under a word of its own: `.outgoing`, the
  result has an edge of exactly one of `types` (none under them) to a shape S matches; `.incoming`,
  a shape S matches has one to the result. Its types must be ones an installed plugin declares.
  MentionQueries' follow `MentionEdge.id` alone, so a shape that mentions itself counts (Mentions'
  `isMentioned` leaves it out).
- **A text format** makes a stored string what a person reads, anywhere (`read`), with what `prepare`
  took; `describes` says so in the vocabulary, beside the attribute (`text (mentions read as
  @Name)`). Mention text reads through [`MentionState.labels`](#the-service-mentionstate), taken as
  the query takes up the file, so a gone target reads as the name its mention holds.
- **Validity is Validation's cache where it's current, else its rules.** `:invalid` and `:warned`
  leave every shape to the main actor (`.onMain`). There, a shape on the board shown, with nothing
  committed since the query started (`context.revision`), takes
  [`cachedResult(for:)`](#a-horizontal-plugin) while it's `.current`; any other runs its kind's rules
  against the board it's on as the app has it (`registry.validationIssues(of:in:
  context.shapes(on: board))`), which is what Validation will find once that board is shown. A
  query never makes Validation read a board, so Validation's first read (100 ms at 10,000 shapes,
  in one turn) is never a query's.

**What a plugin list needs.** `QueriesPlugin()` needs `TopologyPlugin()` (without it, every query
is `no_topology`). Each bridge needs `QueriesPlugin()` (a contribution to a point whose owner isn't
installed is `ownerNotInstalled`) and its own concern's plugin: MentionQueries is refused without
`MentionsPlugin()`, whose `mention` edge type its words follow, while TitleQueries, ValidationQueries
and SelectionQueries find nothing without Titles, Validation or Selection (every kind untitled, no
shape invalid, nothing selected), as `draw`'s bridges do without theirs. `QueryCommandsPlugin`
needs `AutomationPlugin()`, and `--ask` `LanguageModelsPlugin` (else `no_model`). The shipped list
has them after `draw`'s bridges: `QueriesPlugin(), TitleQueriesPlugin(), BoardQueriesPlugin(),
MentionQueriesPlugin(), ValidationQueriesPlugin(), SelectionQueriesPlugin()`, then
`QueryCommandsPlugin(askPrompt: QueryPrompt.system)`.

### What it costs

`./build.sh bench` holds queries on generated boards of 1,000 and 10,000 shapes and files of nested
boards ([QueryBenchmarks.swift](../Tests/BenchmarkTests/QueryBenchmarks.swift), members of
`extension Budget`): main-actor budgets in the test thread's CPU, off-main ones in the answer's
`timings` (or, for what they don't cover, the answer's JSON and `--ask`'s request, every other
thread's CPU while it runs, `cpu {}`), and only the frames on the wall clock. In release, 1,000 /
10,000 shapes, ms:

| What | Budget | Measured |
|---|---|---|
| A query's main-actor time (`queryMain`): reading and resolving `sticky-note[text*="note" i]:not(:inside(*))` and taking up the file, also after a drag event that moved every shape | 0.2 / 0.5 | 0.019 / 0.018 |
| The vocabulary, made on an editor's first query (`queryVocabulary`) | 1 | 0.039 |
| That query off the main actor, first after the file opens, 100 rows: every shape walked, every note's attributes written and its text read with live names (`queryScan`) | 5 / 40 | 2.61 / 23.7 |
| A note by its name (`"Title 5004"`), every name read, off the main actor (`queryTitleOffMain`) | 1 / 5 | 0.32 / 2.87 |
| And on it: every derived name asked, in slices, on a board looked at (`queryTitleMain`) | 0.5 / 4 | 0.094 / 0.78 |
| Notes with an edge to a subboard 100 of them mention, `:edge-to(#…)`, brief rows (`queryByID`) | 0.5 | 0.26 / 0.27 |
| And their rows with their attributes (`queryByIDRows`) | 2 | 1.19 / 1.19 |
| `:downstream-of` along a chain through every shape, and `:component-of(*)` over one component of them all (`queryGraph`) | 3 / 30 | 1.38, 1.49 / 7.20, 8.80 |
| Every construct that walks, and a nest as deep as the language allows, on a board and ten boards deep (`queryPathological`) | 25 / 250 | 4.2 / 37.4, the worst |
| `:invalid` over boards not shown, the main actor's time in all (`queryInvalidHidden`) | 15 / 150 | 4.88 in 3 slices / 48.0 in 24 |
| A slice: 2 ms and the record that crosses it, the longest of any query here (`querySlice`) | 3 | 2.008; the costliest record 0.126 |
| `* --limit 10000` off the main actor: the rows and their JSON, let go of there (`queryRows`) | 15 / 150 | 4.1 / 41.4 |
| That command's main time (`queryRowsMain`: `queryMain` and `queryTitleMain`) | 0.7 / 4.5 | 0.131 / 0.899 |
| Its main time beyond its query's own, making and letting go of the answer (`queryMain`) | 0.2 / 0.5 | 0.053 / 0.092 |
| A commit adding a note while a query holds the file, more than without (`queryHeldCommit`) | 0.1 / 0.5 | none: 0.055 held, 0.076 not / 0.340, 0.363 |
| A drag event's input with the shipped list and a query run first, more than without queries (`queryUpkeep`) | 0.01 | none: 0.0322 with, 0.0323 without / 0.2233, 0.2231 |
| A drag's frames at 60 Hz while `:invalid`'s slices run, the worst (`queryFrame`, wall clock) | 16 | 9.8 / 9.7, none dropped |
| `--ask`'s request without the model, on a board looked at: main (`askAssemblyMain`) | 1 / 5 | 0.157 / 0.836 |
| And off it (`askAssemblyOffMain`) | 3 / 10 | 0.570 / 4.74 |

- **No card is cold.** The schema cards' sync reads every card of a file as it opens, and every
  card as it changes, on any board, so a query finds each card read: a card is read in a slice only
  once its reading has been let go of, past the 4,096 kept. On a board never shown, as the file
  opens, `queryTitleMain` measures 0.150 / 1.35.
- **Rows of derived kinds cost the main actor their names.** 10,000 rows of the generated board
  hold 869 schema cards, which only the main actor can name, so the command is held to `queryMain`
  and `queryTitleMain` together, and what it costs beyond its query's own to `queryMain`: the answer
  is made and let go of off the main actor.
- **Mention text is read twice.** Mentions' text format parses each note's stored text again
  (`MentionText(stored:)`, some 6 µs a note) though the record holds it parsed: about half of a full
  row of a mentioning note, most of `queryScan`, and why full rows of 100 notes are held to 2 ms, not
  `queryByID`'s 0.5 ([Not built yet](#not-built-yet)).
- **Frames** are driven by a strict main-queue dispatch timer (`FrameDriver`), each timed from the
  first fire it answers, so a dropped frame counts as late: a run-loop `Timer` in a windowless
  process fires up to 7 ms late on its own. While slices run a frame starts at most one slice late
  (1.9 ms; 0.1 without), and the worst without queries is 9.0 / 9.3.
- **A held snapshot's copy** (the file's `locations`, some 10,000 entries at 10,000 shapes) is lost
  in a commit's own 0.36 ms; debug builds check that the query holds the file at the commit, so the
  case is real.

**No index, on purpose.** An index would cost every commit, a drag event's included (whose input is
held to 1 ms at 10,000 shapes), and a copy of what it indexes kept in step. What it would save is
small and off the main actor: walking every shape and filtering by kind is some 0.5 ms at 10,000;
named titles are a read per titled shape; derived ones their owners keep; edges and containment are
Topology's already. Attributes are written as JSON only for the candidates a test reaches, and text
read only for those a text test reaches. Should a budget miss on queries asked again and again, the
next step is a warm cache ([Not built yet](#not-built-yet)).

### What it doesn't do

- **Where shapes are.** Positions, sizes and overlaps aren't in the language (`:near`, `:left-of`,
  `:within`, and attributes that hold a place, are `not_built`), and inside is a board's: what's
  drawn within a rectangle's bounds isn't inside it (`cannot_contain`, for a container side that can
  only be kinds holding no board).
- **Shapes typed by schema cards** (`.Task`, `not_built`), attributes inside attributes (`[a.b]`),
  and `=` on an object.
- **Edges as answers.** A query lists shapes: a connection is asked for as its arrow
  (`arrow:starts-at("A"):ends-at("B")`, whose row's `connection` says where it runs), and a mention
  as the shape whose text holds it.
- **Ranking and meaning.** `:contains` is a substring filter; ranked or semantic search would be a
  horizontal of its own.
- **CSS with no meaning here.** Shapes have no siblings, order or columns (`+`, `~`, `:nth-child`,
  `||`), no pseudo-elements, and a query sees no pointer (`:hover`): each is `unsupported`, never read
  some other way.
- **Acting on what it found.** A query selects, reveals and changes nothing. Its rows' ids name the
  shapes in a later query (`#…`), never in a `draw` script, which names shapes by title.

### Testing queries

- **QueryLanguageTests** hold the language on fixture words only (card, box, disc; rank, status,
  due; wire, hot-wire, pipe; the unknown words glows and stacked): trees and spans, the canonical
  form (a fixed point), every refusal (reason, message, hint, offset, length, line, column), the
  limits at their edges, the words and the inventions, and seeded fuzz: trees generated from the
  grammar round-trip, and random edits never crash, reprint as their canonical form when they parse,
  and keep every span inside the text.
- **QueriesTests** hold the engine over fixtures only: CanvasTesting's `Chore` (`ChoresPlugin`: kind
  `chore`, labelled "Task", holding every schema type, and the added `Flagged`, key `flag`), with
  pockets, tiles and links graded as wires; a `caption` names point, board names, words (`:starred`,
  seeded; `:heavy`, off the main actor, counted by `Tally`; `:audited`, asked on it, counted by
  `MainCalls`; `:wired-to(S)`, a relation) and a text format (`text/x-shout`), all in
  `queryPlugins`; `shelf()` and `hiddenShelf()` (a kept-aside owner, a board the app can't show);
  `choresHarness` (every schema type, every operator); `storyHarness` (the design's table of every
  construct, on fixtures: `citesPlugin`'s edges from chores' tags, `pickedPlugin`'s selection,
  `faultyPlugin`'s verdicts); and `wiresHarness` and `danglingHarness` (edges). `answer`, `matched`,
  `refusedAnswer` and `expectMatches` run queries through `awaitResult`, which turns the main run loop
  for the slices, and `plan(_:on:)` reads a plan (`description`, a tree).
- **What runs where** is held by `QueryState`'s debug counters (`liveSnapshots`, `captures`,
  `mainSlices`, `recordsEncoded`, `derivedTitlesAsked`, `verdictsAsked`, `universeWalks`,
  `seededFromAnchors`) and `threadsPlugin` (a name, a text format's `read` and a word's `matches`,
  each off the main thread). `SlowWord`, with `burn(_:)`, makes records cost what a test says: a
  slice's bound with a costly record, the costliest record's stretch after the last read, one slice
  queued at a time, a run-loop `Timer` firing between slices (the run loop's sources run between
  them, not only queue order), cancellation mid-slice, the deadline reached by `h.wait(8_000)` inside a
  slice on the `ManualScheduler`, queries waiting their turn, and a closed file (an editor held only in
  a box a word empties). A word whose `prepare` commits lands a commit in the turn the query takes
  up the file: attributes are the capture's, a derived name the live record's. UpkeepTests hold zero
  upkeep.
- **The bridges' tests** use fixtures only, through `EditorHarness` and `QueryState`: TitleQueriesTests
  CanvasTesting's kinds titled as TitleNamesTests title them (derived names asked on the main actor,
  and read live after a commit lands); BoardQueriesTests a `drawer`, which opens its board with a
  placeholder, and a `crate`, which doesn't and is called by its label; MentionQueriesTests a
  `scribble` of mention text, titled pockets to mention, and a `strand` edge type its words ignore;
  ValidationQueriesTests card and tag rules that count their runs (the board shown answered from the
  cache, another board by its own rules in slices, and never Validation made to read a board); and
  SelectionQueriesTests a `:shifting` word that changes the selection mid-query. BoardQueriesTests and
  MentionQueriesTests name shapes with a names contribution of their own over `TitleProperty`, since
  they have no TitleQueries.
- **QueryCommandsTests** run `query`, `query-vocabulary` and `--ask` as the server does (`start`,
  `finish`, `run`, `answered`, `refused`) over chores, pockets and links, captions naming them,
  "Untitled Pocket" boards, and a `Desk`: `:picked`, the selection word, and `:slow`, asked on the
  main actor; with a `ScriptedLanguageModel` (`queue`, `holdsAnswers`, `requests`). The deadline and
  the repair mark are reached with `h.wait(…)` on the `ManualScheduler` (from inside `:slow` for a
  query run, from `onPicked` for the request's assembly), and `QueryOutput.lastBuiltOnMainThread`
  (debug builds) says where an answer was built.
- **CompositionTests** hold the shipped pieces on the story file, `QueryStory`: the design's "Roadmap"
  (a Payments subboard holding a Refunds one, notes that mention each other and a shape that's gone,
  arrows on a channel and on none, a derived title and an invalid card), its ids
  `00000000-0000-4000-8000-0000000000NN` named by letter (`ids("C, Y")`), `fileOrder`, `file(in:)`,
  `harness(pasteboard:model:)` and `document(windowed:)`. Its untitled, invalid card V holds
  `{"type": "object" "title": "Invoice"}` (a card whose text isn't JSON is named by a title read
  before the error, so the title comes after the missing comma); a card's last reading as an object is
  kept by id for the whole process, so a test that mends V's JSON would title V in every story after
  it: mend a copy. QueryShippedTests run the design's table of every construct row for row
  (`StoryQuery.table`: shapes in file order, the count, the canonical form, each refusal's reason);
  QueryCommandLineTests run `canvas` as built against `CommandServer` on the story open in a
  `BoardDocument` (`configureQueryBoards(pasteboard:model:)`, `startQueryServer(for:)`, which holds the
  board weakly so a closed file's editor can be seen to go, and `RunningCanvas`, a `canvas` left
  running, a held `--ask`, while the test does something else: a `draw` answered meanwhile, a
  `--timeout` that lets go of the model's call, a file closed under it answered `board_closed` at
  once); BoardsTests `:current-board` across a switch (no change set worked out, no snapshot left);
  and SkillTests every `query` and `query-error` block ([Testing plugins](#testing-plugins)).
- **The prompt.** QueryPromptTests hold `QueryPrompt.system` to the language: each of its
  `runnableExamples` answered on the story, each of its `illustrativeExamples` refused there with its
  reason, every query written after "→" listed, nothing that reads as a query left out of the lists,
  every `:word` the language's, a shipped plugin's or one the prompt says not to invent, the kinds,
  edge types and words it assumes the shipped vocabulary's, in its order, and the skill's
  `query-prompt.md` equal byte for byte; so a prompt change lists each new query-like example in one
  of the two lists. "Query eval board" holds `QueryEvalBoard` (59 shapes on six boards: look-alike
  titles, plain arrows, note and schema links, a mention two boards away) to what it's built with,
  and "Query prompt, live" checks each case of `scripts/query-prompts/cases.tsv` offline, its
  reference query finding exactly the shapes it expects; with `QUERY_LIVE=1` it asks the model
  ([`--ask`](#--ask)).
- **BenchmarkTests' Query benchmarks** are above; `cpu {}` sums a command's main-actor jobs without
  polling the run loop, and `FrameDriver` drives frames on a strict dispatch timer.

## Boards

A file holds a tree of boards: the root, and one for each shape of a kind that owns one (the core's
`BoardOwning`; [Boards in a file](#boards-in-a-file)). Boards
([`Sources/Boards`](../Sources/Boards)) is the horizontal that gets you around them, whatever kind
owns them. It builds on Selection (opening), ContextMenus (Open), DetailPanel (the Open button),
Keyboard (⌘↑), Titles (what a board is called) and TableOfContents (the rows a crumb's menu lists),
and none of them learns what a board is.

A board-owning kind opts in with one line, on its own registrar
([OpensBoard.swift](../Sources/Boards/OpensBoard.swift)):

```swift
registrar.shape(SubboardDefinition()) { sub in                 // SubboardDefinition: BoardOwning
    sub.title(pill: false)                                        // Titles names its board
    sub.opensBoard(placeholder: "Untitled Subboard", systemImage: "rectangle.stack")
}
```

or, from a bridge, `registrar.opensBoard(Pocket.self, placeholder:systemImage:)`. The sugar
contributes to Boards' `BoardKinds` point (at most one per kind; its report line reads
`board → subboard "Untitled Subboard"`) and brings, in the same call:

- **Opening**: Selection's `opens("Open")`, which shows the shape's board
  (`editor.showBoard(BoardID(owner:))`), so a double-click, Return, Enter, ⌘↓ and Go › Open Selection all
  enter it ([opening a shape](#selection)), and so does its row in the table of contents: Return
  once the row is picked (in the app's panel, the canvas's Return, since picking a row shows the
  shape's panel and gives the canvas the keyboard), and a double-click only where the list stays
  put, not in the app's panel ([opening a row](#the-table-of-contents)).
- **Open** first in its context menu (`BoardsMenuGroup`, order 0, as Finder's Open is). With several
  selected it opens the first, in selection order.
- **A Board tab** in its panel (`BoardTab`, order 50, a horizontal's feature tab) with an Open button,
  `DetailCommandButton("Open", …, command: .openSelection)`, in a section `enabledWhileReadOnly()`,
  so a locked shape's is enabled too.

`BoardKinds.check` refuses a kind whose definition isn't `BoardOwning` (a bridge's form can't say so
in its types), and a contribution for every kind: only a kind that owns boards has one to open. So
a plugin list with `opensBoard` in it needs Selection, ContextMenus and DetailPanel installed, as a
list with a mentionable kind needs DetailPanel, for its Mentioned In tab.

`BoardsPlugin` itself ([Boards.swift](../Sources/Boards/Boards.swift)) is small:

```swift
registrar.service { BoardCrumbs(editor: $0) }                   // the path, kept for BoardPath
registrar.command(.enclosingBoard, shortcuts: [KeyChord(KeyChord.upArrow.key, .command)],
                  isEnabled: { !$0.board.isRoot && $0.session == nil && $0.editingShapeID == nil }) { $0.goToEnclosingBoard() }
```

- **Going up.** ⌘↑ (and Go › Enclosing Board) runs `editor.goToEnclosingBoard()`:
  the board above, with the shape whose board it left selected there. It's
  `editor.goUp(to: board)` for the parent: any board above the one shown (on `boardPath`), with the
  owner of the board below it on the path selected, as one step back
  (`showBoard(_:selecting:)`), so ⌘[ comes back down. Off the root only, never mid-press, and not
  while a shape is being edited, where ⌘↑ is the text's; on the root its key passes.
- **Names.** `editor.name(of: board, root:)` is what a board is called: its owner's title (Titles;
  a blank one is none), else its kind's placeholder, else its kind's label (`registry.label(of:)`);
  `root` for the root (the file's name). `editor.symbol(of:)` is its kind's symbol (`opensBoard`'s,
  else its label's), nil for the root. Composition's table-of-contents
  heading and the path both read them. `registry.boardPlaceholder(of: kind)` is the placeholder a
  kind opens its boards with (nil for a kind that doesn't), the registry's alone, which both read,
  and so does a [query](#queries): its rows name the boards a shape is inside by the same rule,
  through BoardQueries (BoardsTests' "A board's placeholder" holds it).
- **In the app** (Composition and the app's window): the table of contents' header names the
  board shown, with its symbol and a way up (`ShippedPlugins.contentsHeading(for:rootName:)`, the
  board shown's crumb as a `ContentsHeading` with `up: .enclosingBoard`, called Enclosing Board as
  the Go menu calls it, its tooltip "Enclosing Board (⌘↑)", from Keyboard's
  `registry.help(_:forCommand:)`; on the root the file's name, `detailPanel`'s `rootName`, as the
  window and the path's root crumb have it, else "Board"); the window's subtitle names the board
  shown, nothing on the root, where the title is the file's name (`BoardConfiguration.boardName`,
  which the app fills with `ShippedPlugins.boardName(of:)`, the last crumb's title, and the window
  controller reads observed, so it follows a switch or a rename);
  the path is over the canvas (`ShippedPlugins.boardPath(editor:rootName:)`, the root's crumb the
  file's display name, `BoardViewState.fileName`); and the Go menu has Back (⌘[), Enclosing Board
  (⌘↑) and Open Selection (⌘↓), sent to the board's window controller wherever the keyboard is, and dimmed
  while text has it, where the menu bar leaves those keys to the text (`MenuBar`: AppKit's menus
  take a disabled item's key and beep), so they move its caret. The file opens on the board left
  open, with each board's camera as it was left (`BoardViewMemory`; below).

### The path

`BoardPath(editor:rootName:)` is where you are, as data-canvas shows it: a small capsule of
crumbs over the top middle of the canvas, root first, the board shown last, in a material pill 8
points below the canvas's top edge (`BoardsStyle`). The host places it over the whole canvas, with
`.overlay(alignment: .top)`, so a crumb's menu can stay inside it; only the pill and the menu take
clicks. It shows nothing on the root. `BoardPath.coveredHeight(on:)` is how far down it reaches on
a board (to the pill's bottom, about 35 points; none on the root), which the app tells the editor
(`BoardConfiguration.coveredTop`, the editor's `coveredTop`), so a board's first visit, Zoom to
Fit and `reveal` fit shapes below it, where their titles' pills aren't under it.

```
        ╭──────────────────────────────────────────╮
        │  Plans  ›  …  ›  Kitchen  ›  **Pantry**  │
        ╰──────────────────────────────────────────╯
                           ┌──────────────────────────┐
                           │ › ▤ Groceries            │  the pointer on Kitchen: its rows
                           │   ▤ Spices               │
                           │   ▭ Pantry               │  the way you came, highlighted
                           │   ▭ Fridge               │
                           └──────────────────────────┘
```

- The root's crumb is `rootName` ("Board" when that's empty); the others are `name(of:)`. The
  board shown is bold and isn't a button. Each crumb is at most 180 points wide, truncated past it,
  with its name as its tooltip. The crumbs are separated by ›s, and nothing else marks them (no caret
  for a crumb's menu, below: the owner found ⌄s beside the ›s busy).
- More than four crumbs fold the middle into "…", a menu of the boards it hides, root side first:
  root › … › parent › current (`BoardCrumbs.layout(rootName:)`). "…" is a button built as a board
  above's crumb is (borderless, in its gray and the pill's type), which shows an `NSMenu` of them
  lined up with its leading edge, starting at the pill's bottom edge, where a crumb's menu starts
  (AppKit puts a menu's first item where it's popped up, and its own padding above that, so it's
  popped up `BoardsStyle.systemMenuTopPadding` lower); `BoardPath.foldedMenu(_:editor:)` makes that
  menu, so a test reads and chooses its items without showing it (shown, it's modal). A SwiftUI
  `Menu` draws as a pop-up button, which takes no style from around it and draws without the pill's
  vibrancy: its "…" was darker than the crumbs on a light pill and near white on a dark one. To
  assistive apps "…" is a pop-up button, "Boards between", whose press shows the menu and whose
  children are its boards, each a button going up to its board: an `accessibilityRepresentation`,
  a `Menu` with a primary action (a representation without one does nothing when pressed).
- A crumb, or an item of "…", runs `goUp(to:)`: it shows that board and selects there the shape the
  path came through, as data-canvas's crumbs do, one step back.
- **It redraws only when the path does.** The view reads only `BoardCrumbs.crumbs`, which the
  service makes again when another board is shown, and when a commit changes a board above the one
  shown (they hold the owners whose titles name the crumbs: a file put in place, say), checking
  each one's revision, so a commit on the board shown (a drag's every event) costs a look at the
  path's revisions and redraws nothing. A crumb's title changing is the path changing.

#### A crumb's menu

Every crumb has a menu, as data-canvas's do, though unmarked (data-canvas puts a caret after the
title): the pointer on the crumb shows the menu below it, lined up with it. It lists what's in that crumb's board, as the table of
contents lists it (Boards builds on TableOfContents for it: `ContentsOutline`,
[below](#another-boards-outline)), with the shape whose board is next on the path highlighted: the
way you came. The board shown's crumb lists its own shapes. So from inside a subboard you can jump
into another, or to any shape on any board on the way here, without going up and hunting for it
on the canvas. (data-canvas's crumbs listed their boards' subboards this way at first, and later
the board above instead, VS Code's siblings; the owner chose what's in the crumb's board.)

- **What it lists** is `BoardCrumbs.menu(of: board)`, a `CrumbMenu`: the board listed (the
  crumb's) and the shape highlighted there, nil on the board shown's; the menu is nil for the board
  shown while it has no shapes (kept as commits change it, `shownIsEmpty`, so the path never reads
  the document), and without the table of contents, whose rows a menu shows. The rows are the table of contents' with nothing selected, each as its kind draws
  it, nested rows behind a disclosure triangle.
- **Picking a row** closes the menu, then goes into its shape if its kind opens its board
  (`opensBoard`: `editor.goInto`, as following a mention of a subboard does), and else to it, shown
  selected on its board (`editor.goTo`). Either is one step back, so ⌘[ returns. The highlighted
  row goes back into the board it's the way to, and a row of the board shown's own menu selects
  its shape there.
- **Hover intent**, data-canvas's timers (through `editor.scheduler`, so a test's clock drives
  them): the menu shows once the pointer has stayed on the crumb 150 ms, so a crumb passed over
  shows nothing, and closes 150 ms after the pointer has left it and its crumb, unless it's back on
  one of them by then. Another crumb's menu takes its place once the pointer has stayed on that
  crumb. A click on a crumb closes its menu (the board shown's goes nowhere else), and so does
  another board shown. One menu shows at a time: `BoardCrumbs.openMenu`, which the view drives with
  `pointerEntered(crumb:)`, `pointerExited(crumb:)`, `pointerEnteredMenu()`,
  `pointerExitedMenu()`, `closeMenu()` and `pick(_:)`, and a test headlessly.
- **The panel** is 300 points wide, as tall as its rows up to 360 before it scrolls, 6 points below
  the crumb, on a thick material with data-canvas's shadow, and kept 8 points inside the canvas
  (moved left, and shorter, where the canvas is small). data-canvas's is as wide as its rows,
  from 260 to 380; a lazy list can't measure the rows it hasn't made, so here the width is fixed.
  It opens at the top of its rows. A menu showing or closing redraws only the menu (`CrumbMenuLayer` reads `openMenu`, the pill
  never does), and the menu reads its board's rows, as they are while it shows.
- **The canvas under it.** Where the pill or a menu is over the canvas, the pointer isn't on the
  canvas: `CanvasView` asks the window what's at the pointer, and a view the host put over it has
  it, as the minimap does (the tool hears the pointer leave, so nothing under the path is hovered).

### Subboards

Subboards ([`Sources/Subboards`](../Sources/Subboards)) is the vertical with a board inside: the
`subboard` kind, a card that opens onto a board of its own. It's a whole kind in a handful of lines,
because everything it does is a horizontal's
([Subboards.swift](../Sources/Subboards/Subboards.swift)):

```swift
registrar.shape(SubboardDefinition()) { sub in                     // SubboardDefinition: BoardOwning
    let place = sub.placement(size: Subboard.defaultSize) { Subboard() }
    sub.tool(label: "Subboard", systemImage: "rectangle.stack", shortcut: "b", placing: place)
    sub.title(pill: false)                                          // Titles keeps its name; the card draws it
    sub.opensBoard(placeholder: "Untitled Subboard", systemImage: "rectangle.stack")
    sub.mentionable(tint: { _ in SubboardStyle.border }, following: .opens)   // Mentions: by its title; followed, it's entered
    sub.contentsRow { _ in                                          // in the card's indigo, as its mentions are
        ContentsLabel("", placeholder: "Untitled Subboard", systemImage: "rectangle.stack", color: Color(nsColor: SubboardStyle.border))
    }
    sub.details(header: { $sub in TitleHeader($sub, placeholder: "Untitled Subboard", systemImage: "rectangle.stack") }) {}
}
```

(The row and the header are in files of their own, `SubboardRow.swift` and `SubboardHeader.swift`,
as SwiftUI sugar is.)

- **Its props are its frame**, 240 × 160 placed: `Properties<Subboard>(title: "Subboard") {
  Property("frame", \.frame).required() }`. What it's called is the title Titles adds (`title`,
  marked `x-canvas-owner` in its schema), and its board is the core's, kept under its id, so its
  props hold neither; its schema is marked `x-canvas-board`. Placing one keeps no board: a board
  with no shapes isn't kept.
- **B places one** where the canvas is pressed, following the pointer until release, as every box
  tool does: one undo step, "Add Subboard".
- **The card** (`SubboardDefinition.render`, `SubboardStyle`, world units) is a white card with a
  10-point radius, the canvas's shadow and a 1.5-point indigo border, on two thin plates showing 4
  points below it, each narrower, all inside the frame, so its extent is its box and the minimap
  draws its frame. A 32-point header band, tinted indigo, holds the `rectangle.stack` symbol and the
  title, 15-point semibold on one line (`registry.title(of:)`), or "Untitled Subboard" dimmed. The
  body shows what its board holds: its preview, the core's rough picture of the board
  (`context.drawBoardPreview(ofBoardOwnedBy:in:maxScale:)`, fitted 12 points inside the body at no
  more than a tenth of its size, `SubboardStyle.previewMaxScale`, so a board of one note shows a
  small note in the middle and one of hundreds fills the body; every shape a
  silhouette in one muted gray, as the minimap draws, a subboard inside just its rectangle); until
  that's built, a few frames, and for an empty board, it says how many shapes, from
  `context.shapeCount(inBoardOwnedBy:)`: "Empty", "1 shape", "12 shapes" (the shapes on its own
  board, not those further down). A card too small for the plates is the whole frame. The count is
  read as the card is drawn, and a preview is of one revision of its board, so neither is ever
  stale: a write to the board while another is shown (`transact(on:)`) redraws the canvas as any
  commit does.
- **Zoomed out** the card is its [skeleton](#skeletons) ([SubboardSkeleton.swift](../Sources/Subboards/SubboardSkeleton.swift)):
  fills alone, square (its corners are 3.5 points on screen at most there, so its outline is its
  frame's, as the core draws it), with no shadow, symbol, text or count. Its plates are one fill in
  what they show from afar (their fill, with a quarter of their border's indigo); the card is the
  border's indigo under its header band and its white body, the border never under half a view
  point (just under 35% the card's own 1.5 is about that, so nothing jumps); a bar stands where the
  title is, after the symbol's place, 0.52 em a column of its 15-point semibold
  (`SkeletonText.columns(of:)`: a CJK character or an emoji two, so a title in Japanese or Chinese
  is about as long as in full), no longer than the header leaves it, the placeholder's at half
  strength; and its board's preview is asked for as the full card asks for it, in the same rect
  at no more than a tenth of its board, drawn once it's built and big enough on screen, else
  nothing. Five fills and the preview (`SubboardStyle.plate(_:behind:)` makes a plate without an
  array).
- **Opening it** is Boards': a double-click, Return, Enter or ⌘↓ with it the only one selected, Open
  first in its menu, the Open button in its panel's Board tab, and Return once its row is picked (a
  double-click on the row only where the list stays put, not in the app's panel). ⌘↑ comes back with it selected, and ⌘[ retraces. Its panel's header renames it, a run of
  typing one undo step; its row is its symbol and its title, or "Untitled Subboard".
- **Mentioning it** is Mentions': a note's `@` picker offers it by its title, or "Untitled
  Subboard", with its symbol, and a double-click on its pill (or Go to) enters it
  (`following: .opens`, Selection's `goInto`), from its board or another, one step back.
- **Deleting it** deletes its board and every board under it, as one step, like any shape's;
  undoing it brings them all back with every id.

It ships after the sticky note (the toolbar's Subboard, B), with Boards after Titles, and its props
have a fixture (`Fixtures/kinds/subboard.v0.json`) as every shipped kind's do; a whole file of
boards nested two deep, with notes and a bound arrow on each, is
`Fixtures/files/nested-mentions.v4.json`, read and written back byte for byte (written once notes'
text could hold mentions, though its notes mention nothing); `nested.v4.json` is the same file from
before sticky notes held mentions, read with each board's notes brought up to date; and
`nested-mentions-across.v4.json` is the same file with a note on the root and one two boards down
mentioning each other, read, shown live opened on either board, and written back byte for byte
([Mentions across boards](#mentions-across-boards)).

### The core's part: board previews

A shape that owns a board can show what's on it: `context.drawBoardPreview(ofBoardOwnedBy: id, in:
rect, maxScale:)`, in its render, draws a rough picture of that board into `rect` (world units),
fitted (the board's proportions kept, centered, and no larger than `maxScale` times its own size, if
given: a board of little is small in the middle rather than as big as one of hundreds), and returns true; or draws nothing and returns false, while the
picture isn't built yet, for a board with nothing to show, and for a rect under 16 view points
either way on screen (nothing to see, so a board zoomed out over many owners asks for none), and
the render draws something else (the subboard card, its count):

```swift
if !context.drawBoardPreview(ofBoardOwnedBy: shape.id, in: SubboardStyle.preview(in: body), maxScale: SubboardStyle.previewMaxScale) {
    drawCaption(context.shapeCount(inBoardOwnedBy: shape.id), in: body)
}
```

A [skeleton](#skeletons) may ask for one too, as the subboard's does, in the same rect and at the
same `maxScale`, so the card shows the same picture either side of 35%; the core's default skeleton
never asks.

The picture is the minimap's kind ([Silhouettes.swift](../Sources/Canvas/Rendering/Silhouettes.swift),
the core's, host API, which the minimap draws with too): every shape on the board as a silhouette of
its geometry (its outline filled, or stroked when it's open; under 4 pixels both ways, its bounds,
or a line from its first point to its last when it's open; under a pixel, the pixel it's in: the
rule, `Silhouettes.form`, that the default [skeleton](#skeletons) goes by too), all in one muted
gray, and nothing of what a shape draws, no text and no colors, so a
subboard inside is its rectangle, and a shape costs the same whatever its kind. It's the core's
`BoardPreviews` ([BoardPreviews.swift](../Sources/Canvas/Rendering/BoardPreviews.swift), host API,
`editor.boardPreviews`):

- **Kept by board and revision.** A preview is of the board as one revision of the file had it
  (`file.revision(of:)`), a mask at most 256 pixels on a side. Asked for once the board has changed,
  by an edit or an undo (a revision never comes back), it's dropped, never drawn, and built again.
  The 64 drawn last are kept, the one drawn longest ago going first, but never one the frame before
  drew: with more owners in view than that, those past the number show their count until there's
  room, instead of each frame building one by evicting another, and asking for another frame,
  forever.
- **Built a chunk at a time.** A board asked for waits its turn, those asked for longest ago first.
  At the start of each frame the editor builds for 2 ms (`frameBudget`), a chunk of shapes at a time
  (the shapes' geometry, from a `ShapeContext` with no index, then their silhouettes), as many as
  fit at what shapes have cost so far, and at least one chunk (16 shapes); while any wait, it asks
  for another frame (`editor.scheduler`). One finished at the start of a frame is drawn in it. One
  whose board changed before it was built is dropped unbuilt, and so is one no shape asked for in
  the frame just drawn (`endFrame()`: its owner scrolled away, or the board was left; showing
  another board drops them all), so a frame builds only for what's in view. So ten subboards of
  10,000 shapes in view fill in over sixty to a hundred frames, each one a frame's worth
  (`./build.sh bench`).

## The command line

`canvas` is the app's command line, for agents first and people too: it runs commands on the
boards open in the app, which must be running, and each change shows in the board's window as it's
made. Agents never read or write a board's file; they go through `canvas`, so the file stays the
app's to change.

```
canvas status                           whether the app is running: its version, protocol and boards
canvas boards                           the open boards: each one's id, name, file, which is in front, and what it shows
canvas draw <script>|- [--dry-run] [--reveal] [--board <board>]
                                        shapes, and the edges between them, made, changed or deleted by a script, all at once
canvas kinds [<kind>] [--schema]        what a script can draw, and with what
canvas query <query>|- [--limit <number>] [--count] [--brief] [--fields <attribute>]… [--board <board>]
                                        the shapes of a file a query matches, on every board, in file order
canvas query --ask <question>|- […]     the same, the query written by the app's language model
canvas query-vocabulary                 what this app's queries can name: kinds and their attributes, edge types, words
canvas help [<command>]                 what a command takes (--format json: what the app says, schemas too)
```

The modules, one job each:

| Module | Layer | What it does |
|---|---|---|
| CanvasRPC | wire | What the app and `canvas` say to each other: JSON-RPC 2.0, a message a line, over a Unix-domain socket (`~/Library/Application Support/InfiniteCanvas/canvas.sock`, or `CANVAS_SOCKET`) only this user can reach; what a command is (`CommandSpec`, its params a JSON Schema) and how its params are spelled as arguments; the client, and the listener, which answers each request as a main-actor task of its own (one that waits holds up neither the main actor nor another connection), each connection's answers in the order its requests came, and cancels the requests still running (not notifications) once its client hangs up. Knows no canvas, plugin or AppKit. |
| CanvasCLI | cli | `canvas`: reads its own options, asks the app what it runs (`describe`), reads the rest as one of those commands, runs it, and prints what comes back. Knows only the wire. |
| CanvasUI's `CommandServer` | ui | The app's end: it listens, describes the app, and answers each request on the main actor. `status` and `boards` are its own; it runs the rest on the board a request names (`--board`: an id, a file or a name), or the one in front, on the board inside that file its window shows, each in a task kept against its board, and a board command's result, when it's an object, gains `board: {id, name, shows, showsPath}`, as `boards` lists it, read in the command's own job just before it runs, so an agent sees which board it worked on (a command that knows better says `shows` and `showsPath` in a `board` object of its own, which the server completes: a query's is the board shown as it took up the file). A client gone is answered `cancelled`, and a board closed (`BoardDocument.close()`) answers its running commands `board_closed`, at once, their tasks cancelled and what they return later dropped. |
| Automation | horizontal | The commands plugins give the command line (`AutomationCommands`), its own two, `draw` and `kinds`, and the three points `draw` takes what it doesn't own from. The app hands the commands to its server through Composition (`ShippedPlugins.commands(in:)`, async). |
| DrawScript | foundation | The language `draw` reads (`Script(parsing:)`), and the solver that places what it says (`LayoutProblem.solve()`): pure, it knows no canvas, registry, kind or plugin. |
| TitleNames, PortEdges, ValidationChecks | bridge | What `draw` takes from Titles (names), Ports (edges) and Validation (warnings), each joining Automation to the plugin that owns the concern. |
| QueryCommands | horizontal | `query` and `query-vocabulary`, and `--ask` (on Automation, Queries, LanguageModels and the wire; it declares no point). |
| QueryLanguage | foundation | The language `query` reads (`SelectorList(parsing:)`) and its canonical form: pure, it knows no canvas, registry or plugin. |
| Queries | horizontal | The engine that answers a query about a file ([Queries](#queries)), and its points. |
| TitleQueries, BoardQueries, MentionQueries, ValidationQueries, SelectionQueries | bridge | What queries take from Titles (names), Boards (boards' names), Mentions (`:mentions`, `:mentioned-by`, mention text as it reads), Validation (`:invalid`, `:warned`) and Selection (`:selected`), each joining Queries to the plugin that owns the concern. |

**The commands are the app's, so `canvas` never changes for one.** It knows no command but `help`:
each run asks the app to describe itself, and makes its commands, their arguments and their help
from what comes back. A plugin that adds a command adds it to `canvas`, help and all, and the two
can't disagree about what a command takes. The app carries the `canvas` it was built with
(`Contents/Helpers/canvas`; `build/canvas` links to it), and `canvas` refuses an app that speaks
another version of the protocol (`RPC.protocolVersion`: 2, in which text may be read from standard
input, and an error may say where in a script it is).

**A command is a name, its params, and what it does**, registered with Automation, as `draw` is
([Commands.swift](../Sources/Automation/Commands.swift), [Draw.swift](../Sources/Automation/Draw.swift)):

```swift
struct DrawParams: SchemaDefined {
    static let properties = Properties<DrawParams>(title: "draw") {
        Property("script", \.script).required().keywords(["x-stdin": true, "x-value-name": "script"])
            .description("What to draw: one statement a line (a shape, an edge, a delete or a style), in quotes for the shell.")
        Property("dryRun", \.dryRun).description("Work everything out and say what would happen, changing nothing.")
        Property("reveal", \.reveal).description("Then ease the view to what was drawn.")
    }
    var script = ""
    var dryRun = false
    var reveal = false
}

registrar.automationCommand("draw", "Draw shapes on a board, and connect them, from a script.", discussion: "…",
                            params: DrawParams.self, positionals: ["script"],
                            examples: [CommandExample(#"canvas draw 'edge "API" -> "DB"'"#, "Connect the two.")]) { params, context throws(AutomationError) in
    try draw(params, in: context)       // context.board(): the board --board names, or the one in front
}
```

- **Params are a list of properties** ([Properties](#properties)), whose JSON Schema is what
  `canvas` reads the arguments by: a string as it's typed, a number or an integer read as one, a
  boolean a flag (`--dry-run`, `--no-dry-run`), a fixed number of numbers (the core's point and
  size) as `x,y`, an array of any of those by giving the option again, and anything else as JSON
  (`-` reads it from standard input). Text whose schema says `"x-stdin": true`, as `draw`'s script
  does, is read from standard input when it's given as `-`, and help writes it `<script>|-`: a
  script quoted for the shell breaks at its first apostrophe. Each property is an option (`dryRun`
  is `--dry-run`), those in `positionals` also take their places in order, and help shows each
  one's `description`, its default, and what `x-value-name` calls its value. A param whose schema
  says `"x-timeout": N` (`Property(…).keywords(["x-timeout": 60])`, `--ask`'s) makes `canvas` wait
  up to N seconds for the answer when it's given (`CommandArgument.waits`): a call waits
  `--timeout`, else the longest such wait among the params given, else 10 s, and help says "(waits
  up to N s)". The app checks what comes against the schema and decodes it, so `run` gets its
  params typed.
- **A board command** (the default scope) runs on a board: `context.board()` is its editor. An app
  command (`scope: .app`, as `kinds` is) runs with the registry. `board` is the server's param, and
  `canvas`'s own options (`socket`, `format`, `timeout`, `help`, `version`) are `canvas`'s, so the
  registry refuses a command that declares one; a name the command line can't type (words of
  lowercase letters, digits and hyphens: `draw`, `board list`) or one that's kept
  (`RPC.reservedCommandNames`: the protocol's `describe`, the server's `status` and `boards`,
  `canvas`'s `help`); a positional that isn't a param; and two commands of one name.
- **An error says why, and what to do**: `AutomationError(message, reason:, hint:)`, where `reason`
  is a word an agent can branch on (`unknown_kind`) and `hint` is often the command, or the line,
  to write instead; a name that's nearly one gets a "did you mean". An error about a script or a
  query says where: `line:` (from 1), `column:` (from 1, in characters) and `length:` (in
  characters) of what's wrong on it, and `statement:` (that line as written: `draw`'s trimmed, its
  comment left out; a query's whole, so the column counts from its start); and a command that finds
  several problems at once throws the first, with every one in `errors:`. Anything else an agent
  can use goes in `details:` (`--ask`'s `transient`, the `query` a model wrote), under names of the
  command's own: a detail named like one of the error's members (`reason`, `message`, `hint`,
  `line`, `column`, `length`, `statement`, `errors`) is left out, whether the error has that member
  or not. They reach `canvas` as the error's data (`line`, `column`, `length`, `statement`, the
  details beside them, and `errors`, each `{line, column, length, statement, reason, message,
  hint}` and its details), which it prints beside its own members in JSON, never over them, and as
  text as `canvas: line 3, column 12: <message>`, the statement indented, carets under the columns
  it names, as a terminal draws them (a tab before them stays a tab, and an emoji or a CJK character
  takes two cells: `Invocation.caret(under:column:length:)`), the hint, then
  a line for each further problem. `canvas` prints a result on standard output (JSON when that isn't a terminal,
  which is how agents run it, or text, whose tables lead with `line`, `did`, `id`, `name`, `kind`
  and `title`, those a table has, end with sentences
  (a warning's `message`), which they never cut, and list what a row has that isn't a value (a
  kind's attributes) under it; `--format` says which), an error on standard error, and exits 0
  when it's done, 1 when the app couldn't do it, 2 when the command line is wrong (standard input
  that can't be read, or isn't UTF-8, included), and 3 when the app couldn't be reached or didn't
  answer in time. The app doesn't drop a request it's slow to answer: after a timeout
  (`timed_out`) it may still do it, so check before running it again.
- **A command changes a board as anything does**: through `editor.transact`, on the main actor, so
  the window shows each change, the board is edited and saves itself, read-only shapes refuse, and
  services hear the change set; its commit is an undo step of its own, named as the command names
  its transaction (`transact("Draw")`). Who made a change is recorded only as whether an agent did:
  a command that changes the board for one says so (`transaction.byAgent = true`, as `draw` does),
  and its commit carries it (`ChangeSet.byAgent`), so a service that acts on a person's edits
  leaves it be (a schema card's sync, which would ask a language model, takes what an agent wrote
  as in step). An agent's name on its commits is still to come.

**A file's boards.** A file can hold boards inside its shapes ([Boards in a file](#boards-in-a-file));
a command works on the one its window shows, `editor.board`, as the window does: `document`,
`transact` and the undo step its change makes are that board's (a `draw` is one step, Draw, there,
and undoing it from another board shows that one first). `canvas boards` says which, for each open
file: `shows`, the board shown (`"root"`, or the id of the shape that owns it, as a `BoardID` is
written), `showsPath`, the boards from the root down to it, and `shapes`, how many it holds;
`canvas status` names the front file's as `frontmostShows`; and a board command's result names it
in its `board` (`id`, `name`, `shows`, `showsPath`, as `boards` has them), read in the
command's own job as it starts: a command that doesn't wait (`draw`) runs in that job, so no
switch of board comes between the two. A [query](#query) says where it ran itself, the board shown
as it took up the file (`QueryResult.shown` and `shownPath`, `:current-board`'s), which may be
later than its request (it waits its turn, and `--ask` waits on the model), and the server
completes that `board` with the file's `id` and `name`. A query reads every board of the file the
app can show, whichever the window shows, and names each row's board (`board`, and `inside`, the path's names for the boards it's
inside); but no command addresses another board of a file yet ([Not built yet](#not-built-yet)):
an agent that wants to draw on a subboard's board asks the person to open it.

The app that holds the socket's lock (`canvas.sock.lock`, beside it) is the one listening: a second
copy of the app gives up and runs without the command line, and a socket that one that crashed left
behind is taken over. A command's options may also come before its name
(`canvas --board 2 draw - < plan.txt`), as agents often write them.

### A command may be async

A command that waits on something (a language model's answer, a query answered off the main actor)
answers later: `runAsync:` in place of `run:`, its output `Encodable & Sendable`
([Automation.swift](../Sources/Automation/Automation.swift)), as [`query`](#query) does
([QueryCommands.swift](../Sources/QueryCommands/QueryCommands.swift)):

```swift
registrar.automationCommand("query", "Find the shapes of a file that a query matches, …", discussion: "…",
                            params: QueryParams.self, positionals: ["query"], examples: […],
                            runAsync: { (params: QueryParams, context: AutomationContext) async throws(AutomationError) -> JSON in
                                try await query(params, in: context, asking: asking)   // its answer built as JSON, off the main actor
                            })
```

- **It runs on the main actor, awaiting**, and the main actor is free while it waits: the listener
  answers each request as a task of its own, and `CommandServer` runs each command in a task kept
  against its board, so a command that waits holds up neither drawing nor another connection's
  commands. On one connection only the answers keep their order: a `draw` sent after a query may run
  before the query's answer comes.
- **Its output is written as JSON off the main actor** (`AutomationCommand.encoded`, `@concurrent`,
  handed the output whole, `consume`), where it's freed too, so a large one costs the main actor
  neither its writing nor its freeing. One that's the wire's `JSON` already passes through as it is
  (`JSON(_: JSONValue)` makes one; `query` builds its answer member by member, off the main actor).
  `run:` is unchanged: it never suspends, and answers in the turn it's asked in, as `draw` and
  `kinds` do. Write the `runAsync:` label out: a trailing closure that doesn't await picks `run:`.
- **It may be cancelled.** `canvas` hanging up (its timeout, ^C) cancels the request's task,
  answered `cancelled`, which nobody reads; closing its file answers it `board_closed` ("The board
  was closed before the command finished.") at once, and cancels it. What a cancelled command
  returns later is dropped, so a long wait looks at `Task.isCancelled` (a query does every 256
  shapes and before every slice; a model's call is cancelled at once). Every command, `draw`
  included, runs one main-actor hop after its request, so one cancelled, or whose file closed, before
  it starts never runs.
- **`canvas` waits as long as its params say**: the longest `x-timeout` among those given (`--ask`'s
  60 s), else 10 s, unless `--timeout` says ([above](#the-command-line)). The protocol stays 2: a
  param's `x-timeout`, and an error's `column` and `length`, are what an older `canvas` passes over
  (it waits 10 s, and says `timed_out`). `Registry.runAutomationCommand(_:params:editor:)` and
  `ShippedPlugins.commands(in:)` are async, and a test awaits them with TestKit's `awaitResult`.

### draw

`draw` is how an agent puts things on a board. It reads a script in a small language whose idea is
[reladraw](https://github.com/reladraw/reladraw)'s (Apache-2.0; the attribution is in
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md), and the language isn't called that): each
line says what a shape is, what it's called and where it sits against shapes already named, never
at coordinates, and the app works out only the distances.

```
sticky-note "Web" text: "Browser app"
sticky-note "API" right of "Web" text: "Public HTTP API"
subboard "Payments" below "API"
edge "Web" -> "API"
```

A shape's title is its name. A statement about a title the board has changes that shape (only what
it says, and it moves only with a placement), and one about a title it doesn't makes a new one. A
gap is a minimum among the shapes the script places; shapes already on the board stay put, and
are kept clear of; and whatever is ambiguous (an axis nothing settles, two shapes with nothing to
hang on, two that would overlap with nothing saying which side either sits on) is refused rather
than guessed. A placement is worked out once: the board keeps positions, never `right of "API"`.
The language itself, every construct and every refusal, is written for agents in the canvas skill
([`.claude/skills/canvas`](../.claude/skills/canvas/SKILL.md): `SKILL.md`, a tour, and
`reference/language.md`, the whole of it), and CompositionTests runs every example in it and
holds its tables of kinds to `canvas kinds`, so the skill can't drift from the app
([Testing plugins](#testing-plugins)).

How it's built ([Draw.swift](../Sources/Automation/Draw.swift) and the files beside it), in four
steps, the first three against the board as the run starts:

1. **Read.** DrawScript's `Script(parsing:)` cuts the script into statements, one a line: shapes
   (any first word but `edge`, `delete` and `style` is a kind word, left for Automation to
   resolve), edges, deletes, and styles, which it merges into the statements that name them. An
   attribute that isn't the language's own is a key and a value, left for Automation to check
   against the kind. The language's own words are enums with implicit raw values (`Keyword`,
   `LanguageKey`, `EdgeKey`, `Direction`, …), never string literals, so the id audit never sees
   another module's id there (Ports' `channel`, Titles' `title`). Every line that can't be read is
   reported, up to 20.
2. **Resolve** (`Drawing`): each kind word against the registry (a kind is drawable when a tool
   places it, `registry.placement(for:)`); each title, through DrawNames, to the one board shape it
   names (restated) or to none (made); each attribute by the kind's schema, own and added
   properties alike (`KindVocabulary`, over the core's [`KindSchema`](#a-kinds-schema): a value
   read as its property's type, in draw's own words when it can't be, and JSON held to the
   schema before it's read, `registry.schemaViolations(of:kind:)`, since reading drops a member its
   type doesn't have without a word: an unknown member, or a value of the wrong type anywhere in
   it, is `invalid_value`, with a "did you mean" over the object's members; the naming property and
   coordinates refused); each placement's targets; each edge's ends and attribute keys; and each
   delete's shape, with the connections on it (those DrawEdges' `ends` joins to it, and any other
   of the edge kind bound to it, `record.boundShapes(in:)`: one with an end left free) and the
   boards it owns (a subboard's, and every board under it, `file.subtree(ownedBy:)`: refused,
   `read_only`, if one holds a read-only shape, as a transaction would refuse the delete; else said
   in a warning). A new shape starts as what its tool places (`placement.shape(at:)`), and every
   shape's attributes are set by the core (`registry.shape(_:setting:)`), so the registry builds
   every record, and what the kind derives from them (a schema card's height, a note's from its
   text, `DerivedProps`) is the size it's placed at, unless the statement gives one. What a shape is bound to
   (`ShapeReferencing`) must be on the board as the script leaves it, or it's `invalid_value`; what
   it only names (`ShapeNaming`, a note's mentions) needn't be. A kind whose titles are only
   derived (a schema card's, from its schema's `"title"`) takes no title in its statement
   (`untitlable`), and a restated one whose derived title changes is renamed (`renamed`, held to a
   rename's rules), where one that's named too (no shipped kind is) keeps its derived title or is
   refused (`renames`). Problems that don't depend on one another are all reported, up to 20,
   each statement's first.
3. **Place** (DrawScript's `LayoutProblem.solve()`, from a problem built in DrawLayout.swift): the
   shapes that move are free boxes (new ones, and those restated with placements); what their
   placements name that stays put is fixed (board shapes, `board`, `view`); and every closed board
   shape the script doesn't move or delete is an obstacle. The obstacles are filed once a run, in
   paint order, in a grid of cells about a shape's size (`ObstacleIndex`, a pass over the board),
   and the solver asks for them by region, each answer kept for the run: it asks again after every
   push, mostly about boxes that haven't moved, so however often it asks, a question costs what's
   near the box it's about (`./build.sh bench` holds a draw of 20 notes, each pushed along a row
   of the 10,000-shape board to its end, to 150 ms). DrawScript
   knows only boxes: a part on an outline (a round shape's corner) is worked out by Automation from
   the shape's `ShapeGeometry`, and handed over as a rect. The solver's first problem is the one
   reported. A zone isn't in a box's way (`Solver.isZone`): an obstacle that wholly holds a
   restated box where it already sat, however snug; a shape the box is placed against, at twice
   that one's area; the box where it lands and another shape too, at twice the box's area, so a
   region that frames what's in it takes a legend in any corner of the view or the board on it;
   or the `view` the box is placed against, or its drawing with nothing to hang on is drawn in,
   whatever its size (that drawing's spot isn't kept clear of it). A shape held is a board shape,
   or a free box the zone counts (`Solver.counted(by:in:)`, once a solve for each zone asked
   about): one on it for a reason of its own, `inside` or `on` it, a zone for it without counting
   any free box, or placed against one that counts, worked out from those up until nothing is
   added, so two new shapes can't hold each other on an empty note. What holds only the box where
   it lands is a neighbor, and in the way: an empty note or card next door, or a lone shape that's
   the whole board, for a box inside `board` (a note holding a badge of its own is a container
   like any other). A box held where it lands wholly on such a region at twice its size is
   `unordered`, its hint saying what the region holds (nothing yet, or no shape wholly: one hangs
   over its edge) and offering first to place the box elsewhere, since the region may be a note
   whose words it would cover, then, if the region is meant to hold shapes, to place a first one
   inside it. With the boxes placed, it says which obstacles each sits on as zones
   (`LayoutSolution.zones`, never what it's `inside` or `on`), which it's raised above and warned
   about hanging over.
4. **Apply**, in one `editor.transact("Draw")` (DrawCommit.swift), one undo step, which says an
   agent made it (`transaction.byAgent`: a schema card's sync takes what it wrote as in step, and
   asks the model nothing): the deletes; the shapes, each after
   every script shape it's drawn inside or on, new or restated, so that shape is in place first
   (new ones inserted on top; restated ones updated in place, and raised above a shape they're
   moved inside or on, or a zone they sit in where they land, while they're writable: before a
   change that locks one, after one that unlocks it, and not at all for one read-only throughout,
   which placing left as it was); the edges, through DrawEdges, against `transaction.shapes`, so either
   end may be new, each one's channel and sides checked as it's made, the first that's wrong
   ending the run; then the result, read back from `transaction.document`, and the warnings. Anything wrong throws out of
   the body, and a body that throws commits nothing, and makes no undo step
   ([the document](#the-editor-the-document-and-drawing)).
   A dry run is the same transaction, whose body throws its finished result (a private error
   `draw` catches), so on the same board a dry run and a real run say the same.

Before any of it, a run is refused while a drag is under way on the board (`editor.session`,
`busy`: its Escape would put back what the script moved), or a press is held
(`undoHistory.isPressHeld`: whatever commits during a press is part of its undo step, so the run
would be taken back with it). Once it's placed, a
real run ends an edit under way on a shape it changes or deletes (`editor.endEditing()`), and works
the script out again if ending it changed the board, so what's typed lands first. It applies the
run once and throws it away before it does, since some of what a run can fail on (an edge that
can't be drawn) is found only as it's applied: a run that fails, or leaves that shape as it is,
leaves the typing be. The view the script's `view` and its unplaced drawing go by is where the
camera is headed (`editor.cameraTarget`), so a draw just after a `--reveal` goes where that one's
glide ends. The selection is left alone, and so is the camera,
unless `--reveal` asks to ease it to fit what the run made or changed
(`editor.animateCamera(to: Camera(fitting:…))`, as selecting a row of the table of contents does).

What comes back (`DrawResult`, with the server's `board`) says what each statement did, in line
order, and never by id, since titles are the names:

```json
{"board": {"id": 2, "name": "Architecture", "shows": "root", "showsPath": ["root"]},
 "changes": [{"line": 2, "did": "created", "kind": "sticky-note", "title": "API", "at": [[620, 350], [200, 200]], "inView": true},
             {"line": 4, "did": "connected", "kind": "arrow", "from": "Web", "to": "API", "channel": "note-link"}, …],
 "warnings": [{"line": 3, "message": "\"Ship v1\": Blocked: say why in the notes.", "severity": "warning", "attribute": "notes"}]}
```

A row's `did` is `created`, `moved` (its bounds changed), `updated`, `renamed` (with `was`),
`unchanged`, `deleted`, `connected` or `reconnected`. A shape's row has its `kind`, `title` and
`at` (`[[x, y], [width, height]]`, world units), `inView` while the board is in a window, and
`pushedPast`; an edge's has `from`, `to` and the attributes DrawEdges declares (`channel`), but a
deleted connection with an end left free has neither end to name. A
warning (`line`, but none for one about the whole run; `message`; `severity`; and the property
it's about, `attribute`) is an issue DrawChecks finds on a shape made or changed (an `error`
too: the shape is drawn, invalid; without DrawChecks, a bound of its schema it breaks), a push
past another shape (or a move along with a shape pushed, which isn't in `pushedPast`: that's
only what the shape was kept clear of itself; what a shape went past is said once each way it
went, so a list's members, pushed past a wall in turn, aren't also said to have gone along with
one another past it), a named side facing away from the
other end, a new title nearly one the board has, a shape hanging over the edge of a zone it
sits in (a zone isn't in its way, but doesn't keep it in), how many shapes
landed out of view, a shape resized where it stays that now overlaps another, a name a shape
drawn holds (a mention in its text) of a shape that isn't in the file or is on a board the app
can't show (by id, since the script wrote it: `"Plan": text names shapes that aren't in the file:
…; they show as missing`), or a deleted subboard's boards and what was on them. A dry run's
result says `dryRun: true`. The result's `board` is the server's: the board the run worked on,
read as it began.

### What draw takes from other plugins

Automation knows no title, port or validity. `draw` takes each from a point Automation declares,
keyed so it takes at most one contribution, from a bridge between Automation and the plugin that
owns the concern ([DrawPoints.swift](../Sources/Automation/DrawPoints.swift)). Without one, `draw`
does without:

| Point | Sugar | What `draw` gets | Without it | Shipped |
|---|---|---|---|---|
| `DrawNames` | `registrar.drawNames(name:namingProperty:isDerived:fold:)` | What a shape is called; the property of its kind's schema a title is written to (nil: its shapes can't be named); whether the kind works names out itself; how a title a script writes is folded | No titles: a titled statement is `no_names` | TitleNames |
| `DrawEdges` | `registrar.drawEdges(kind:attributes:sides:ends:make:)` | The kind edges are (nil while nothing makes them); the attribute keys an edge takes beside `from:` and `to:`; what an edge may leave a kind on, by side (for `kinds`); which shapes a connection joins; a connection made or changed | No edges: an edge statement is `no_edges` | PortEdges |
| `DrawChecks` | `registrar.drawChecks { record, shapes in … }` | What's wrong with a shape made or changed, as the script leaves the board: `DrawIssue`s (a message, whether it's an error, the property it's about) | Each shape checked against its kind's schema (`registry.schemaViolations(of:)`) | ValidationChecks |

The three bridges, whole but for PortEdges' policy ([TitleNames.swift](../Sources/TitleNames/TitleNames.swift),
[PortEdges.swift](../Sources/PortEdges/PortEdges.swift), [ValidationChecks.swift](../Sources/ValidationChecks/ValidationChecks.swift)):

```swift
// TitleNames: a shape is called what Titles calls it, and a title is written to the one Titles keeps.
registrar.drawNames(name: { record, registry in registry.title(of: record) },
                    namingProperty: { kind, registry in
                        registry.properties(for: kind).contains(TitleProperty.key) ? TitleProperty.key.rawValue : nil
                    },
                    isDerived: { kind, registry in registry.titleIsDerived(kind) },
                    fold: { TitleProperty.folded($0) })

// PortEdges: an edge is the connector's connection, on the channel this bridge picks.
registrar.drawEdges(kind: { registry in registry.makesConnections ? registry.connectorKind : nil },
                    attributes: [ChannelProperty.key.rawValue],
                    sides: { kind, registry in EdgeChannels.sides(of: kind, in: registry) },
                    ends: { record, registry in registry.connectionEnds(of: record) },
                    make: { request, existing, shapes throws(AutomationError) in
                        try EdgeChannels.connection(for: request, existing: existing, in: shapes)
                    })

// ValidationChecks: what's wrong is what Validation finds, schema bounds included.
registrar.drawChecks { record, shapes in
    shapes.registry.validationIssues(of: record, in: shapes).map { issue in
        DrawIssue(issue.message, isError: issue.severity == .error, field: issue.field)
    }
}
```

- **Names are titles.** A kind is named when it opts into the title Titles keeps (`title()`, or a
  bridge's `registrar.title(K.self)`), derived when Titles works its titles out (`title { … }`),
  and may be both (no shipped kind is): a derived name names a shape only while it's the only one
  so called, and a statement that would change it is refused (`renames`). The
  board's names are read once a run, from the shapes that aren't kept aside. None of the bridges
  writes another module's id: TitleNames reaches `title` through `TitleProperty.key`, and PortEdges
  `channel` through `ChannelProperty.key`.
- **An edge statement is an upsert.** `ends`, over the transaction's document, finds the
  connections already drawn from one shape to the other (either way round for `<->`; one drawn the
  other way round is asked for its own way). None: `make` gets `existing` nil, and draws one
  (`connected`). One: `make` changes it, or hands back `existing` itself when nothing would change,
  which is how `draw` tells `unchanged` from `reconnected` (`==`). More is `ambiguous_edge`. `make`
  gets an `EdgeRequest`: its ends by id, the sides named (`EdgeRequest.Side`, Automation's own,
  since a bridge that imports only Automation can't read DrawScript's), whether `<->` puts a head
  at its start too, the attributes it declares as written, and its ends' names and the edge as
  written, for messages. It returns the connection, not inserted, and throws
  `AutomationError(message, reason:, hint:)`, which `draw` gives the statement's line; its closure
  says `throws(AutomationError)`, as a command's does. `draw` checks what comes back (the edge
  kind, a new id or the existing one, naming only shapes on the board) before it inserts or
  updates it. `DrawEdges.check` refuses an attribute key the language keeps (`from`, `to`,
  `style`), one a result's row has of its own (`line`, `did`, `kind`, …: a row carries an edge's
  attributes beside its own members), one a script couldn't write before a colon, and one declared
  twice.
- **Checks see the board as the script leaves it** (`transaction.shapes`), so a rule that looks up
  another shape sees the ones drawn with it. Each issue is a warning on the statement's line.

### Edges and their channels: PortEdges

An edge is a connection the connector makes [without a drag](#connecting-without-a-drag), on a
channel PortEdges picks from Ports' [port table](#a-kinds-ports) as a drag from a port would: a
connection runs only from a shape with a dot on its channel to one that takes it. The policy,
`EdgeChannels`:

- **`channel: <id>`** is that channel, which some installed plugin must declare (else
  `invalid_value`, listing the channels). The start's kind must have a dot on it, and the end's
  kind take it as a target (else `no_channel`, saying what each end has, by side); a side named
  without such a port is `invalid_value`.
- **`channel: none`** is a plain connection, on no channel, from and to any side.
- **Unwritten**, it's the first of the start's dot channels (on `from:`'s side, if named; else all
  its dots', in the table's order) that the end takes as a target (on `to:`'s side, if named).
  With none, it's plain if neither kind has ports on anything (rectangles, subboards), and
  otherwise `no_channel`, whose hint says `channel: none` draws one anyway; a named side narrows
  the channels, so one without a port leaves none.
- **A connection on a channel never ends where it starts**: a shape joined to itself on one is
  `no_channel`.
- **One already drawn keeps its channel**: another written is `invalid_value`, with the hint to
  write `delete edge "A" -> "B"` above the line and draw it again, and a side named must have a
  port on its channel.
- **Before any of it**, the connector must be able to connect both ends in the board as the script
  leaves it (`registry.canConnect(_:in:)` with `transaction.shapes`), and afterwards to make the
  connection (the binding rules allow it): otherwise it's `cannot_connect`, naming the end.
- **What edges are** is the connector's kind only while it makes connections without a drag
  (`registry.makesConnections`): a connector that only draws from ports leaves `draw` with
  `no_edges`.

### query

`query` is how an agent reads a file: which shapes are there, what they're called, what's inside
what and what connects to what, answered by [Queries](#queries) about every board of the file
`--board` names, whichever board its window shows. It changes nothing.

```
canvas query --board 2 - <<'EOF'
"Payments" sticky-note:mentions("API gateway")
EOF
```

The language is taught by the canvas skill: SKILL.md's "Reading the board" tours it, and
`reference/query.md` is the whole of it, where every block is a query run on the story file
([Testing queries](#testing-queries)). The commands are QueryCommands'
([QueryCommands.swift](../Sources/QueryCommands/QueryCommands.swift)), a horizontal on Automation,
Queries, LanguageModels and the wire (the answer is the wire's JSON), which declares no point and
knows no shipped kind: its help writes `<kind>` and `<title>`, and `--ask`'s prompt comes from
Composition.

- **Params** (`QueryParams`): `query`, positional, read from standard input as `-` (`x-stdin`: a
  query is full of what shells mangle, so a heredoc with a quoted delimiter); `--ask <question>`
  instead (up to 2,000 characters, `-` too; given, `canvas` waits up to 60 s, its `x-timeout`);
  `--limit` (1 to 10,000; 100 unless it says, and `count` is always of all);
  `--count` (no rows); and `--brief` (rows without their attributes) or `--fields <attribute>`,
  given again for each (only those, whole). Exactly one of a query and `--ask`, and not `--brief`
  with `--fields`, else `invalid_params`. `--fields` naming an attribute a shape hasn't leaves it out
  of that row.
- **The answer** is `{board, query, count, rows, warnings?}`: `board` where it ran, `shows` and
  `showsPath` (the board shown as it took up the file, `:current-board`'s), which the server
  completes with the file's `id` and `name`; `query` as the language writes it, `count`, the rows
  as `QueryRow` writes itself ([What a query sees](#what-a-query-sees)), `asked` with `--ask`, and
  no `rows` with `--count`. It's built as the
  wire's JSON member by member, off the main actor, where the result is let go of too
  (`QueryOutput.json`, handed the result whole), never written through `JSONEncoder` and read back,
  and `runAsync:` passes it through. As text, the rows are a table (`id`, `kind`, `title`, `board`,
  `inside`), each one's attributes under it.
- **A refusal** carries the query's reason, message and hint (most often the query to write), and
  where it is:
  `line`, `column` and `length` in characters, and `statement`, the line as sent, whole, so the caret
  `canvas` draws lands on what's wrong (`AutomationError(error, in: text)`); several problems that
  don't hang on one another come at once, each where it is, in `errors`. A line longer than 200
  characters (`QueryOutput.quoted`) is quoted around what's wrong, `…` where it's cut, the column and
  length counted in what's quoted (`QueryError.located(in:quoting:)`). Beside the language's reasons
  (`QueryError.Reason`, [Queries](#queries)), `no_queries`: the app has no `QueriesPlugin`.
- **`canvas query-vocabulary`**, an app command (it reads the registry, on no board:
  `QueryVocabulary(registry:)`), is what this app's queries can name: `vocabulary`, the block
  `--ask` sends the model (the kinds, the edge types and the plugins' words); `kinds`, each `{kind, label, naming, holdsBoard, attributes}`
  (`naming` is `named`, `derived` or `none`, and not `titles`, Titles' plugin id, which the id audit
  keeps a module that doesn't depend on Titles from writing; each attribute with what it takes,
  `KindSchema.compactType`, and how a text format reads it: `text (mentions read as @Name)`);
  `edgeTypes`, each `{type, under?, summary?}`, in the tree's order; and `words`, each `{word, takes,
  summary, example, from}`, the language's own first (`from: queries`), then plugins' in plugin
  order. Without `QueriesPlugin` it answers `no_queries` too (`registry.answersQueries`, which looks
  up `QueriesPlugin`'s mark, since an app command has no editor to ask).

#### `--ask`

`canvas query --ask "which notes mention the gateway?"` has the editor's language model write the
query, runs it, and answers as a query does: `asked`, the question, and `query`, what the model
wrote, for the agent to check it asks what the person meant. `QueryAsking`
([QueryAsking.swift](../Sources/QueryCommands/QueryAsking.swift)) runs on the main actor, awaiting,
never holding it:

1. **Bounds** are armed on `editor.scheduler`: `AskStyle.deadline` (55 s, under the 60 `canvas`
   waits) for the whole command, and `AskStyle.repairBefore` (40 s) for a second try; the steps run
   in a task of their own, which the deadline cancels.
2. **The request** (`AskRequest`) is the system prompt, and one user message of tagged blocks, each
   left out when it has nothing to say: `<question>`; `<vocabulary>` (`QueryVocabulary.text`);
   `<board>`, where the person is: the names of the boards on the way to the one shown, and what's
   selected, by title and kind, or kind and id, up to 20 (`queries.whereThePersonIs(selectedLimit:)`,
   whose selection is `registrar.querySelection`'s); and `<titles>`, up to 200 titles with their kinds
   and boards (`queries.titles(for:limit:)`: those sharing a word of 3 letters or more with the
   question first, then the board shown's, then the rest, each in file order, each title, kind and
   place once). Both are run as queries are, off the main actor. Nothing else leaves the machine:
   never a shape's text.
3. **The answer** is read (`QueryAsking.parse`): trimmed and unwrapped (`ModelAnswer.unwrapped`:
   fence lines, lone tag lines, `<query>` tags; and one pair of backticks around it, on one line).
   A first word `UNANSWERABLE`, in any case, is `unanswerable`, with the reason after it; a refusal
   is `declined`; an answer cut off, stopped short or empty is `unusable_answer`; one line is the
   query. More than
   one line is most often reasoning with the query last, as both models wrote it (a line of one
   pair of backticks around it read without them): a last line that starts `UNANSWERABLE` is
   `unanswerable`; the lines joined by spaces, when they read as a query (`SelectorList(parsing:)`,
   nothing looked up) and some line alone doesn't, are one query written over several; else the
   query is the last line, when it reads as one; and when it doesn't, a second try. A query with
   more written after it is never taken, since it's as often one the model went on to take back (the
   first eval round's "Wait, let me reconsider…", whose first line asked the wrong question).
4. **The query** is run (`queries.run`, which checks it first). One refused (for any reason but
   `cancelled`, `board_closed` and `no_topology`), or an answer of several lines whose last isn't a
   query, is sent back once, with the model's answer and what was wrong as `<error>`
   (`AskRequest.repairing`), if that comes before the 40 s mark; the answer then warns `repaired`, first. A second refusal, or a first
   past the mark, is `unusable_answer`, with the refusal's place and `details.query`, what the model
   wrote last.

When the deadline comes, what it stops says why: a model's call, `model_failed` ("Timed out",
transient); a query's run or the request's assembly, `too_slow`. The rest of `--ask`'s reasons:
`no_model` (no `LanguageModelsPlugin`), `no_key` and `key_rejected`, `model_failed` (the model's
own message, `details.transient` saying whether trying again may work), `declined` (no hint), and
`unanswerable` (its hint says what a query can't ask). Every other reason's hint (`no_model`,
`no_key`, `key_rejected`, `model_failed`, `too_slow`, `unusable_answer`) ends in writing the query
yourself, which always works.

- **`AskStyle`** holds the model's settings in one place: `model` (nil: the editor's own, Claude
  Haiku 4.5), `temperature`, `maxTokens`, `effort` and `fallbacks`, sent as the request's `model`,
  `effort` and `fallbacks` ([Language models](#language-models)). `.haiku` is the editor's model at
  temperature 0, 400 tokens; `.sonnet` is Claude Sonnet 5.5 (`claude-sonnet-5-5`) with no
  temperature (it refuses any but its default), 2,048 tokens, effort `low`, and the service's
  fallback (`.default`: a cyber or frontier-LLM decline is answered by Sonnet 5; any other still
  comes back `declined`). What ships is `AskStyle.shipped`: `.sonnet`, the only model that clears
  the evaluation's bar (below), named on every request, while the editor's own model stays Haiku
  4.5, which the schema cards' sync asks. `QueryCommandsPlugin(askPrompt:askStyle:)` takes another,
  and `AskStyle.named(_:)` is a model's style by its id (the evaluation's `QUERY_MODEL`).
- **The prompt** is Composition's `QueryPrompt.system`
  ([QueryPrompt.swift](../Sources/Composition/QueryPrompt.swift)), handed to
  `QueryCommandsPlugin(askPrompt:)` since its examples name the shipped kinds, edge types and words:
  a raw string literal, the prompt byte for byte (as `SchemaPrompts`' are), with its query-like
  examples in two lists, `runnableExamples` (each answered on the story file) and
  `illustrativeExamples` (each refused there, with its listed reason), which QueryPromptTests hold
  to the language. The canvas skill carries it byte for byte
  ([`query-prompt.md`](../.claude/skills/canvas/query-prompt.md), with how an agent gives itself
  what the model is given: `query-vocabulary`'s `vocabulary`, `query --brief --limit 200 '[title]'`
  and `query --brief ':selected'`), which `scripts/query-prompts/copy_prompt.py` rewrites from the
  literal and QueryPromptTests hold equal.
- **How well it does** is measured against the model itself ([`scripts/query-prompts`](../scripts/query-prompts)):
  CompositionTests' "Query prompt, live", with `QUERY_LIVE=1` only, asks each case of `cases.tsv`
  (on the story file and `QueryEvalBoard`, 59 shapes on six boards) as `--ask` asks it, scored by the
  shapes its answer matches. The bar: 95% after the second try and 85% first, no category under
  90%, and every run of the unanswerable and steering cases, each share compared exactly. The
  cheaper model that clears it ships ([Language models](#language-models)): Sonnet 5.5. Round 2
  (`results.tsv`'s r2-haiku and r2-sonnet, 192 runs each) put Sonnet 5.5 at 192 of 192 first try,
  every category at 100% (p50 1.18 s, p90 1.42 s; some 4,200 tokens in and 15 out, about $0.009 a
  question), and Haiku 4.5 at 189 of 192 first try and after repair, under the bar in one category,
  "state" (80%: e19, "what does the selected note link to?", `:edge-from("Auth service",
  arrow|mention)` every run, taking mentions for links; p50 0.64 s; about $0.003 a question).
  Round 1, before the language and prompt changes it prompted, was 88% first try and 98% after
  repair for Sonnet, 89% and 91% for Haiku.

### kinds

`kinds`, an app command (it runs with the registry, on no board), is the language's vocabulary,
all of it read from the registry, so it's always what's installed. For each kind (`KindSummary`,
by name):

- `kind`, `title` (its schema's) and `tool` (the label of the tool named for it,
  `ToolID(placing:)`: the one that places it, or draws it by hand);
- `drawable`, and `why` not: its tool draws one by hand (a line, by its drag) or it has none
  (`registry.placement(for:)` is nil either way), it's what edges are (DrawEdges' kind), or it's
  named like a word of the language (`edge`, `delete`, `style`);
- `names`: `named` when DrawNames gives its titles a property, else `derived` when DrawNames says
  it works them out, else `none`;
- `size`, what its tool places (`"200x200"`);
- `attributes`: each property of its schema a script can write, with a compact type read off the
  schema (`KindSchema.compactType`, which follows a `$ref` as `canvas` does, keywords beside it
  over its target's): `todo|doing|blocked|done`, `number ≥ 0`, `text (≤ 80)`, `true|false`,
  `date (YYYY-MM-DD or date-time)`, `JSON {blue, green, red: 0…1}`, `JSON [{isDone, text}]` (an
  object's members sorted, and an id nobody writes left out). The naming property isn't listed (a
  title goes after the kind, in quotes), nor are coordinates, found as any property whose schema
  is, or holds, the core's rect or point (`core.rect`, `core.point`), never by name. A property
  named like one of the language's keys (`size`, `gap`, `overlap`, `style`, `title`) is listed as
  one a script can't write;
- `edges`: DrawEdges' `sides`, the channels an edge may leave it on, by side;
- and with `--schema`, its whole JSON Schema (`registry.schema(for:)`).

As text, at a terminal, each kind is a row, and its attributes and edges are listed under it.

### Making and changing shapes without the pointer

The core lends what a plugin needs to make and change shapes without the pointer. `draw` starts a
new shape from its kind's placement, and sets every shape's attributes with `shape(_:setting:)`:

- **`registry.placement(for: kind)`**, what the kind's tool places: `placement.size`, and
  `placement.shape(at:)`, the shape it puts down with its middle on a point, in no document yet. So
  a new shape starts as the tool's would, with whatever its placement sets (`setting(_:to:)`).
- **`registry.shape(kind, properties:)`**, a shape from its properties as one JSON object, own and
  added side by side as its kind's schema describes them: the inverse of `record.propertiesJSON`.
- **`registry.shape(record, setting:)`**, some of a shape's properties set from one JSON object,
  each read as `shape(_:properties:)` reads it; null puts one back to its default, and is refused
  for a required one. A property it names is replaced whole: an object value (a struct's members)
  or a list is read afresh, and the members it leaves out take their defaults, not the shape's; a
  value that's none (a blank title, `isNone`) is none. Everything the object doesn't name stays
  exactly as it was (decoded over the old props, never written out and read back, so a date keeps
  its fractions of a second, and a statement that changes nothing leaves a shape equal to itself),
  but what the kind derives from what's set (`DerivedProps`, run when any of its own properties is
  set: a schema card as tall as its description, a note as its text); and so do the shape's id, its place in the stack, its
  metadata and its values kept aside, which can't be set; nor can anything on a shape kept aside.
  Nothing changes until the record goes in a document: `transaction.update(id) { $0 = shape }`.

Both throw `ShapePropertiesError` (a kind nobody registers, a property the kind doesn't have, a
value that can't be read). Reading is lenient, as a board's must be (a newer app's board may have
members this one doesn't know): a member an object's type doesn't have is dropped. To refuse it
instead, check the JSON first: `registry.schemaViolations(of: properties, kind:)` is where an object
of a kind's properties (some of them will do) breaks its schema, `additionalProperties` for a
member its type hasn't, as `draw` does. A shape past its schema's bounds is made, with a warning, as the app
makes any. What a shape's props are bound to (an arrow's ends, through `ShapeReferencing`,
`record.boundShapes(in:)`) must be on its board: a shape bound to one that isn't would stay bound
to it, and nothing would let go, so `draw` refuses it (`invalid_value`), one on another board of
the file too. What it only names ([`ShapeNaming`](#values-that-name-shapes), a mention) may be
anywhere, or gone: it's drawn, with a warning for a name of a shape in no board of the file (or
one the script deletes), or on a board the app can't show.

## Schema cards

Schemas ([`Sources/Schemas`](../Sources/Schemas)) is a vertical whose shape is a JSON Schema: a
`SchemaCard` (kind `schema-card`; `frame`, `schema`, `prompt`), placed empty with the Schema tool
(S). On the canvas the card is what the schema holds **in words**, its description (`prompt`),
typed on the card; the schema is its panel's, and `SchemaSync` keeps the two saying the same thing
through the editor's language model (below). The schema is kept as **text**, not a parsed value: a
dictionary would lose the order its properties were written in, and a schema being typed isn't
JSON for a while. Nothing restricts what it says; the plugin reads the keywords most schemas use,
and the rest stays in the text. Its name is its own root `"title"`, so there's one place to say it:
a title Titles derives (`schema.title(symbolInPill: true) { … }`), never the `TitleProperty` Titles
keeps for notes and subboards, so the kind's schema has no `title` of its own; `setTitle` rewrites
just that member. Titles shows it as it shows a note's, in its pill ([adornment](#adornments))
above the card's top-left corner, after the kind's `{}` (`symbolInPill`: the kind's symbol, its
tool's `curlybraces`), since a white card of words doesn't say it's a schema; an untitled card has
no pill, as an untitled note has none.

```swift
registrar.service { SchemaSync(editor: $0) }                                           // below
registrar.shape(SchemaCardDefinition()) { schema in
    let place = schema.editingPlacement(size: SchemaCard.defaultSize) { SchemaCard() } // 240 × 52, typed into
    schema.tool(label: "Schema", systemImage: "curlybraces", shortcut: "s", placing: place)
    schema.validate { shape, _ in SchemaReadings.reading(of: shape).issues }
    schema.title(symbolInPill: true) { SchemaReadings.reading(of: $0).shown.title }   // its pill: `{}` and the title
    schema.contentsRow { shape in ContentsLabel(…, systemImage: "curlybraces", badge: "6") }  // top-level fields
    schema.schemaPanel()                                                               // the header and the Schema tab
    schema.schemaLinks()                                                               // ports: a schema to a schema
}
registrar.channel(SchemaLink.self)
```

- **The card** is white, with a note's corners (`SchemaStyle.cornerRadius`, 4), and shows its
  description as a note shows its text: the same attributes (the system font at 16 points, every
  line 19 tall, string drawing's pitch: `SchemaStyle.textAttributes`), 16 points in from its edges
  (`SchemaCardMetrics`), and nothing of its schema; with no description it's blank. It has no hue:
  the kind's magenta is its row's symbol and its ports' dots. Its text reads where a note's does, so
  going to one (`goTo`) leaves it at 70%, and it says no zoom of its own. An untitled card is
  `SchemaCard.untitled` ("Untitled") in its header and in its row.
- **Typing it.** The card is `Editable`: the Schema tool's placement edits the card it places (an
  editing placement, so placing it and typing its description are one step, "Add Schema"), and
  Return, a double-click, or a click on the only selected card edits one, as a note is edited
  ("Typing"). Its editor, `SchemaDescriptionEditor`
  ([SchemaDescriptionEditor.swift](../Sources/Schemas/SchemaDescriptionEditor.swift)), is laid over
  it as a note's is: a `DetailTextView` on TextKit 2 (`SchemaDescriptionView`), its text set with
  the render's attributes, starting a point higher (`SchemaStyle.editorInset`), so its lines fall on
  the render's, pixel for pixel but anti-aliasing, and nothing moves as editing starts
  (SchemasTests' "Schema card description"). Return says the description is done, as it did in the
  panel it came from, and ends editing, as ⌘↩ and Escape do; ⇧↩ is a new line. Begun from a press,
  the caret goes where it was (`placeSelection(at:selectingWord:)`), and the camera follows it as
  the card grows past the window's edge (`caretFrame`, `EditContext.keepInView`).
- **Its height** is its description's, set in the same transaction: `setPrompt` sets the text and
  fits the height to it at the card's width (`prompt` is `internal(set)`, so nothing writes it
  without), as a note's text fits a note (`SchemaStyle.fittedHeight`: its lines, measured as string
  drawing sets them, with half a point spare, and the padding), at least a line: a new card is
  240 × 52. The editor writes it with every change, so the card grows and shrinks with what's typed,
  in the typing's step, and grows one too short for its description as editing begins (a card
  drawn with a `size:`); one drawn taller keeps its height until it's typed into. The width is the
  person's. A card made from properties, or given a description that way (`canvas draw`), is as
  tall as its description (`DerivedProps`). The schema is a plain `var`, and sizes nothing.
- **Reading the schema.** `JSONReader` is an order-preserving JSON reader: every object's members
  in order, every value and key with its range (UTF-8 offsets), errors with a line and column a
  person counts, tokens for coloring, and no text that crashes it (it refuses nesting past 256).
  `SchemaDocument` reads a schema from it: its title (even from a half-typed text, if the root's
  `"title"` came first) and its top-level fields (`properties`, then `patternProperties`). A
  `SchemaField` reads its type (`SchemaFieldType`: `format` in place of `string`, `enum`, `const`,
  `$ref`, `oneOf`/`anyOf`/`allOf`, type lists, boolean schemas, arrays of anything, and a type
  that isn't one of JSON Schema's seven as written, `unknown("ninteger")`, never `any`) and its own
  fields a level at a time, following `$ref`s within the document, each step bounded, so a `$ref`
  in a circle ends.
- **Cost.** A card's schema is read once: `SchemaReadings` keeps a reading per card and text,
  compared with the card's text by identity (the record's own string) before anything, and read
  again only when that text changes; its name, its row, its rules, its panel's header and the sync
  read the one text, and drawing a card reads none. A card keeps the readings of up to 4 texts
  (`versionsPerCard`): ids are unique within a file, not across files, so a file duplicated in
  Finder and opened beside its original has the same cards, and once one is edited each window's
  reading is kept beside the other's instead of taking its place; typing adds a reading, and the
  card's used longest ago goes. Readings of deleted cards, and of cards on a board read again, are
  dropped (the sync hears it), and past 4,096 the quarter used longest ago; debug builds count
  reads (`SchemasPlugin.schemasRead`).
- **Zoomed out** the card is its [skeleton](#skeletons) ([SchemaSkeleton.swift](../Sources/Schemas/SchemaSkeleton.swift)),
  and the render always draws it in full: a white card with no shadow but a light gray edge inside
  its frame, half a view point (`SchemaStyle.skeletonEdgeWidth`, a device pixel on a Retina screen)
  of 0.9 gray (`SchemaStyle.skeletonEdge`), where the full card's shadow showed as a pixel or two of
  gray on the light canvas (a softer rim on the dark one), and its description greeked as a note's
  text is, by the core's `SkeletonTextBars` with the note's metrics (`SchemaStyle.skeletonText`);
  its name is its pill's, drawn blank above it. Three fills, whatever it says (the edge, the card
  inside it, and every bar in one `fillSkeletonText`), and nothing read or measured: a frame draws
  thousands. The edge is the frame filled under the white inset, not an even-odd ring, which cost
  about three times as much (as measured). The card is square (its corners are under 2 points on
  screen there, and a rounded card costs a third more), so its outline is the default one, its
  frame's.
- **Typing through a broken text.** A keystroke in the middle of a member leaves the schema not
  JSON for a moment, so while a card's text isn't a JSON object, what's shown of it stays what its
  last one that was said (`SchemaReadings.shown`, kept this session, and dropped with the card, or
  when its board is read again from disk, since it's in no version of the file): its title and so
  its pill, its row and badge in the table of contents, its panel's header. They don't flicker;
  Validation's red outline says it's broken. What acts on the text reads the text itself
  (`document`): Validation's rules, the sync, the editor's colors, a rename.
- **Rules.** A text that isn't JSON is an error at its line and column ("Invalid JSON: expected a
  property name at line 6, column 34."), as is a root that isn't an object; `required` naming a
  property its object doesn't have is a warning, as is a `type` that isn't one of JSON Schema's
  ("“ninteger” in birthYear isn’t a JSON Schema type.").
  Validation's own rule checks a card against its kind's schema, as it does every shape: `schema`
  and `prompt` are strings without bounds, so no text breaks it.
- **Ports.** As notes do, a card has ports on a channel of its own: `SchemaLink`
  (`schema-link`, the card's accent), on every side but the top, where its pill is, as a note's
  ([SchemaLinks.swift](../Sources/Schemas/SchemaLinks.swift)). A schema links only to a schema,
  and the link says nothing more yet.
- **The panel** is where the schema is written. Its header is a `TitleHeader` over the root
  `"title"`, with the count of its top-level fields under it ("6 fields"; nothing where it has
  none). Renaming rewrites that member alone, so it can't while the text isn't a JSON object (the
  name shows, at full strength, as text: `isRenamable: false`), and while the model writes the
  schema it's dimmed. Its Schema tab has the **JSON** (a `DetailCodeEditor`, colored by
  `JSONReader.tokens`, the token where it stops being JSON underlined), and under it what
  Validation finds, a status line each, in its words and tone (the line and column say where,
  since lines don't wrap), then the sync's status, whichever side it writes: "Updating schema…"
  or "Updating description…", with a spinner, or why it failed, in a fragment ("Anthropic
  overloaded", "Unusable answer"), in the warning's tone (red is the schema's own errors), with
  what to do (`SchemaSyncFailure.remedy`): Retry; Open Settings… alone, for want of a key, since
  saving one tries again by itself (it sends `AnthropicSettingsView.showSettingsAction`,
  `BoardMenus.showSettings`'s selector, up the responder chain for the app to answer); nothing
  (`editByHand`), where asking again would get the same answer: a schema too long to rewrite, or
  one cut off (`SchemaSync.tooLongMessage`), and "Claude declined" (at temperature 0 it would
  decline again; rewording the description is what helps, and that edit syncs). The side being
  written is read-only and dimmed: the JSON (`detailUpdating`), or the card's description, whose
  editor, if it's open, is read-only and faint (`SchemaStyle.updatingOpacity`) and shows the
  description the model wrote once it lands (it follows the sync's status and the card itself,
  `EditContext.shape`, observed). The section's commit holds the sync weakly: a box that loses the
  keyboard as its window closes commits after the board has gone.
- **Completing the JSON.** The JSON completes as VS Code completes a JSON Schema: ⌃Space (or ⌥⎋,
  or F5) in the panel's JSON lists what can be typed at the caret, a keyword with its description
  after it, a type's names, a `required` list's properties, and a pick writes it as it goes in,
  opening the list again where it leaves the caret among more (picking `type` lists the type
  names). The list and its keys are the code editor's
  ([`completions:`](#anatomy-and-conventions)): what's typed ranks what's offered, a pick is
  typing as far as the card knows (one step of its "Change JSON" run, which the sync hears as a
  person's edit, syncing on a commit as ever, and not before the list closes otherwise: a pick
  that opens it again leaves JSON waiting for a value, `"type": ""`), and while the model writes
  the schema nothing opens. The card maps its completions to the editor's in `SchemaCode`
  (`DetailCodeCompletions(_:)`), candidate for candidate.
  `JSONCaret.at(_:in:)` reads the half-typed text leniently and says where the caret is: the path to
  its object or array, a key, a value or an element, what's typed and what a pick replaces, the
  members around it, a comma missing. `JSONCompleter`, generic over any JSON Schema, walks the
  schema along that path (`$ref`s, read against the document; `properties` and the
  `patternProperties` a name matches, as the validator reads their patterns, else
  `additionalProperties`; `prefixItems`, `items`; `unevaluatedProperties` and `unevaluatedItems`
  for what nothing else holds; every `allOf`/`anyOf`/`oneOf` branch) and offers the keys the
  object's schemas list (in order, described, none deprecated or there already) or the values the
  place's schemas give (consts, described or not, enums, examples, the type's `{}` `[]` `true`
  `false` `null`, defaults), each written as it goes in: a key with a value to type into
  (`"type": ""`, `"minLength": 0` selected, a number its bounds allow), commas where needed,
  `reopens` where the caret lands among more. It matches nothing against what's typed; the list
  does. What it knows of JSON Schema is data: `MetaSchema`, the 2020-12 meta-schema flattened, its
  keywords in the order offered, each with a description, and `x-canvas-when`, the app's one
  annotation (`minLength` matters only where `type` is or lists `string`: left out beside
  `"type": "number"` until something's typed, then last).
  `SchemaCompletions.completions(in:at:)` is the card's, in UTF-16, adding in code only what no
  schema can say: a `required` list's names, the same object's `properties`; a `$ref`'s targets,
  `#` and the root's definitions; and that `$vocabulary` goes only in the root and `$schema` only
  in the root or a subschema with an `$id`.

### Keeping the description and the schema in step: `SchemaSync`

Edit the description and Claude rewrites the schema; edit the schema by hand and Claude rewrites the
description to say what it now holds. `SchemaSync`, the plugin's service, does it per card, through
`editor.languageModel`:

- **When.** Only the person's edits to the two sides start a sync: never its own write, a board
  read again from disk (a revert, a reload; `ChangeSet.replacedDocument`, which takes every card
  of the file afresh, those it left as they were too, their calls and timers dropped), a change to anything else about the
  card (a move, a lock, a restack), or an agent's write (`ChangeSet.byAgent`: `canvas draw`'s
  `schema:` or `prompt:`), whose two sides are taken as in step, as a card's first seen are, its
  call and timer dropped: an agent writes both sides as it means them, and never spends the
  person's key by writing one. A commit (the description done: editing it on the card ended,
  however it ended, Return, Escape, a click elsewhere or the keyboard going to the panel among
  them, which services hear, `EditorService.editingDidEnd`, and which commits an edit still
  waiting, the scheduler's next turn, so editing that typed nothing asks nothing, a failure
  included, and an undo, a draw or a file put in place that ended it leave nothing to ask; ⌘↩ in
  the schema, or the keyboard leaving it) syncs at once; otherwise it's
  `SchemaSync.idleDelay` (3 s) after the last keystroke, on `editor.scheduler`, but not while the
  JSON's completion list is open (`SchemaSync.completing`, from the code editor's
  `onCompleting:`): the person is still choosing, though the text a pick leaves may be whole
  JSON already, so the wait starts once the list closes.
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
- **While a call is out** the side it writes is read-only where it's edited, and the status says so. If it changes anyway
  (by a plugin, a test), the answer is dropped; edits to the other side wait for it: they sync
  when they're committed or 3 s after the last, as ever, or as soon as it lands if either came
  while it was out; a card deleted or read again meanwhile drops it; a card locked meanwhile gets
  nothing written (nothing is tried, so nothing's refused) and its pair stays as it was, so its
  edit syncs once it's unlocked. A failure leaves both sides as typed and says why, with Retry (the
  next commit tries again too; a key saved in Settings retries the cards that failed for want of
  one, `languageModelKeyDidChange`); a cancelled call says nothing; `NO_CHANGE` writes nothing and
  makes the pair in step. A
  schema is written as the model wrote it, never laid out again (its order is the model's, which
  keeps the person's; the prompt asks for two spaces, a member per line, plain arrays on one line);
  a description is written with `setPrompt`, so the card fits it; the write is the sync's own, and
  starts none.
- **Undo.** Typing the description on the card is a step as a note's typing is ("Typing", or "Add
  Schema" for a card placed and typed into), typing the JSON or renaming the card one a run
  ("Change JSON", "Change Schema"), and the sync's write is one of its own ("Update Schema",
  "Update Description"), taken with the pair it leaves in step (which it takes as it hears its own
  write, inside the step). Undo and redo
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
- **Boards.** It keeps every card of the file, whichever board it's on (ids are unique across the
  file), so a card's sync goes on while another board is shown: a commit that comes as its board is
  left (editing its description ending, the keyboard leaving the panel), its timer, its call out. The answer is written on the
  card's board without showing it (`editor.transact(on:)`), as a step made there, so undoing it,
  from anywhere, shows the card's board first, then puts back the pair from before the answer as on
  any board. A card whose board goes with its owner (a subboard deleted) is dropped with its call,
  and one that comes with a board (a paste, a deletion undone, `ChangeSet.elsewhere`) is seen, or
  gets back what it last synced from the step. A whole file put in place takes every card afresh,
  whichever board it shows after (`BoardChange.isFileReplaced`), as a board read again does.
- **What it asks** is `SchemaPrompts`: the two system prompts (raw string literals, each its text
  byte for byte, which [`scripts/schema-prompts/evals.py`](../scripts/schema-prompts) reads out of
  the Swift, so the quick evals test exactly what ships), the user message (tagged blocks, each
  trimmed: `<previous_prompt>`, `<prompt>`, `<schema>`; or `<prompt>`, `<previous_schema>`,
  `<schema>`; empty ones left out, tags and all), 16,000 tokens at most for a schema and 2048 for a
  description, temperature 0, no prefill or stop sequences, and `parse` (the answer trimmed, then
  unwrapped of any code-fence line and its own block's tags, from either end, until none is left,
  `ModelAnswer.unwrapped` (LanguageModels', which `--ask` reads its answers with too): the model
  sometimes adds them though the prompts ask for neither; a stop other than the end of its
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
  conversation as `ModelMessage`s, `maxTokens`, `temperature`, `stopSequences`, and `model` and
  `effort`, below) in, a `ModelResponse` (its text, `stopReason`, token counts) out, or a
  `LanguageModelError` (no key,
  unauthorized, rate limited, overloaded, another status with the service's message, the network, a
  malformed answer, no answer in time, cancelled), each with a short `message` for a person and
  `isTransient` for whether trying again later may work. A message names what went wrong in a
  fragment, never what to do about it, which the button beside it says: "No API key", "API key
  rejected", "Rate limited", "Anthropic overloaded", "Anthropic error 500", "Can’t reach
  Anthropic", "Timed out", "Unusable answer"; a request the service refused (a 4xx) is its message's
  first sentence ("Your credit balance is too low to access the Anthropic API"), with the key taken
  out, were it ever in it. Cancelling the task asking throws `.cancelled`.
- **The app's model.** `AnthropicModel` calls Anthropic's Messages API from the app, with
  URLSession (no SDK, no streaming, no retries), Claude Haiku 4.5 by default, or the model a
  request names (`ModelRequest.model`, by its id: for a plugin whose task another model does
  better). It sends what a request says and leaves out what's nil: `temperature` (Sonnet 5.5 refuses
  any but its default), `effort` (sent as `output_config.effort`; Haiku 4.5 refuses a request
  that says one), and `fallbacks` (`ModelFallbacks.default`: the service answers a decline with the
  model it recommends for the decline's category, sent as `"fallbacks": "default"` with the header
  `anthropic-beta: server-side-fallback-2026-07-01`, neither unless asked; an answer another model
  gave reads as any other, the block that marks the switch not being text). Nothing streams, so the answer comes whole, all at once: it waits a minute, and
  a second more for every 100 tokens
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
- **Reading an answer**: `ModelAnswer.unwrapped(_:tag:)` takes off what a model sometimes wraps its
  answer in, though its prompt asks for neither (fence lines, a line of a tag alone, the answer's own
  block tags), from either end until nothing changes; the schema card's sync and `--ask` both read
  their answers through it.
- **`--ask`** ([`canvas query`](#--ask)) asks a model to write a query, through the editor's
  `languageModel`, with the settings `AskStyle` holds: what ships is `AskStyle.shipped`, `.sonnet`,
  Sonnet 5.5 named on every request (no temperature, effort `low`, the service's fallback), chosen by
  the live evaluation's round 2 (192 of 192 first try; Haiku 4.5 missed the bar in one category);
  the schema cards' sync stays on the editor's own model, Haiku 4.5. Its prompt is
  measured against the live model by CompositionTests' "Query prompt, live" (`QUERY_LIVE=1`;
  `scripts/query-prompts`), which asks every case on the shipped list with `AnthropicModel` and the
  key Settings saves.
- **Tests** pass a `ScriptedLanguageModel` ([Testing plugins](#testing-plugins)), never the network,
  but for the two live evaluations, SchemasTests' (`SCHEMA_LIVE=1`) and `--ask`'s (`QUERY_LIVE=1`),
  which `./test.sh` never sets.

## Snapping

What a drag moves snaps to the shapes around it, as it does in Keynote and Freeform: its edges and
its middle line up with theirs, and it keeps the spaces between them even, centered between two or
as far from one as the space beside it, while guides show what lines up. It's a horizontal
([`Sources/Snapping`](../Sources/Snapping)) with no extension point of its own: every kind with a
frame takes part, and the core lends one hook, the [translation
adjuster](#the-cores-part-the-translation-adjuster), which Snapping claims
([Snapping.swift](../Sources/Snapping/Snapping.swift)):

```swift
registrar.service { _ in SnapState() }                                          // the drag under way, told of others' writes
registrar.translationAdjuster { editor, start in SnapDrag(start, in: editor) }   // nil for a drag that moves no frame
```

- **What snaps** is everything a `TranslatingSession` moves: the selection dragged with the select
  tool, and a shape just placed, which follows the pointer until the release. It snaps as one rect
  (the frames it moves, together, as they were when the drag began) to the frames of the shapes in
  view but its own, along each axis on its own, to the nearest within 8 view points whatever the
  zoom (tldraw's `snapThreshold`) of: one of its edges or its middle onto one of theirs (tldraw's
  snap points, the corners and the center); its middle onto the middle of the space between two
  neighbors, if it fits there; its far edge onto where a space as long as the one between two
  neighbors would begin before them, or its near edge onto where it would end after them. Ties go
  to edges and middles before spaces, and to the near edge first. Along an axis where it snaps it
  lands exactly on the line; along the other it follows the pointer exactly, as without Snapping.
- **Guides** show while the drag lasts, in tldraw's snap red (hsl(0, 76%, 60%), light and dark
  alike), a view point wide: for every line it's on exactly, snapped there or not, a line through
  the corners and centers on it, a ✕ at each; for every space it makes as long as one between
  neighbors, the spaces of that length side by side with ticks at their edges and middles, those
  in a row before and after them too (tldraw's). `editor.snapGuides` is what shows (`SnapGuide`:
  `.alignment(axis, at:, points:)`, `.spacing(axis, gaps:)`), none once the drag is over.
- **Always on**, unlike tldraw's (on only while ⌘ is held, or in its snap mode), but only once the
  pointer is past the drag threshold from the press, so a click, whose lone box follows the pointer
  from the press, moves it no more than the pointer does. ⌘ or ⌃ held once the drag is under way
  lets what moves follow the pointer exactly: Keynote's ⌘, and ⌃ too, as either lets an arrow's end
  bind to nothing. (At the press they're the select tool's: ⌘ on a shape starts a marquee, and ⌃ is
  the secondary click.) A key pressed or let go mid-drag takes effect at once, where the pointer is,
  and one let go counts as held for 150 ms (`editor.effectiveModifiers`), so letting go of ⌘ with
  the mouse leaves what moved where the pointer put it. Kept to one axis with ⇧ (the core's),
  it snaps along that axis alone, and shows only its guides.
- **Kinds with a frame** (`BoxShapeProps`: notes, schema cards, subboards, rectangles) snap and
  are snapped to, locked shapes too (they stay put, and don't count in what
  moves). Kinds without one neither snap nor are snapped to: arrows, whose geometry follows the
  shapes they join (tldraw's arrows can't be snapped to either, `canSnap`), and lines.
- **Only shapes in view**: the view's world rect when the drag first snaps, read again once the
  camera moves or a shape the drag doesn't move changes (a plugin's write, an agent's). With no view
  (`editor.viewportSize` zero, as in a headless editor), nothing is in view, and nothing snaps.
- **Only neighbors' spaces count**: each frame's nearest past its far edge along the axis that
  overlaps it across the axis, and its nearest short of its near edge, so a third frame between two
  keeps their space out, and a frame has at most two where tldraw compares every pair in view. What
  moves must share the stretch across the axis that the two share by more than the threshold
  (tldraw's asks for any of it), so snapping along the other axis never takes it out of that
  stretch, where the space's guide wouldn't show.
- **Cost.** `SnapTargets` (pure: world units in and out) keeps the frames' edges and middles along
  each axis in order, and their neighbors. It's made when a drag first snaps, from what's in view,
  some 6 ms with 10,000 shapes in view (at 10%, where a frame takes over 100 ms to draw them); each
  event after is a binary search for each edge and a pass over the neighbors' spaces, 0.12 ms with
  10,000 in view, and a drag at 100% costs what it did without Snapping. `./build.sh bench` holds
  the first event to a frame and the rest to a drag event's input budget.
- **Undo** is as without it: the drag is one step, Move, and Escape puts everything back.

### The core's part: the translation adjuster

`registrar.translationAdjuster { editor, start in … }` lets one plugin decide where a
`TranslatingSession` puts what it moves. It gets the drag as it begins (`TranslationStart`: what it
moves, read-only shapes left out, and where it was pressed, in world units) and returns a
`TranslationAdjuster`, kept for the drag, or nil to leave it following the pointer. On each drag
event the session asks `adjust(_:along:for:in:)` how far to move the shapes, given how far the pointer has
come from the press, and moves them by that: along an axis it gives back as it came, a box follows
the pointer exactly as with no adjuster (the POC's `pointer.world − grabOffset`, which the
characterization tests pin); along one it changes, each box moves by exactly what it says from where
it began, so an edge snapped to a line lands on it; and a `CustomTranslation` kind's move gets what
it says. While ⇧ keeps the drag to one axis, `along` says which (`TranslationAxis`), the delta is
zero across it, and what the adjuster says across it is ignored: what moves stays there. When held
keys change mid-drag, the session asks again with the same pointer, and moves again. `draw(in:)` draws with the session, above the world overlays, so what it shows goes when the
drag does. At most one plugin may claim it; the report shows it as `translation adjuster`.

## Capabilities

Some behavior belongs to a kind itself rather than to a concern others can join. That's a
**capability**: a protocol refining `ShapeDefinition`, found with `as?` by the module that declares
it, the core or a horizontal.

| Capability | For | Used by |
|---|---|---|
| `Editable` | Edited in place: an editing placement, or opening it (Selection's double-click, Return and ⌘↓), unless its kind has an opener of its own. Supplies an `NSView` laid over the shape; writes go through `EditContext.update`. | StickyNotes, Schemas (its description) |
| `CustomTranslation` | Moving by its own rules instead of by its frame, when a `TranslatingSession` moves it (dragging the selection, a shape just placed). When a drag starts, `beginTranslation` gets the shape, every shape moving with it and the starting transaction (committed on its own, before the first move), and returns a `ShapeTranslation`: a closure run on every drag event with the drag's delta (the pointer's, or what the [translation adjuster](#the-cores-part-the-translation-adjuster) made of it: Snapping's snap), after the moving boxes have moved. A kind without a frame needs this to be movable at all. | Arrows (alone, bound ends slide on their shapes; with a shape they're bound to, they keep every binding); Polylines (every point by the delta) |
| `HandleProviding` (Selection's) | Draggable handles on the only selected shape. The select tool finds, draws and hit-tests them; `pressHandle` returns `.drag` or `.consumed`, and `dragSession` does the dragging. | Arrows |
| `BrushHitTesting` (Selection's) | Whether the marquee touches it, when the brush overlaps its bounds without containing them. Default: `ShapeGeometry.isHit(byBrush:)`. | Arrows (against the visible arc) |
| `DerivedProps` | Props that hold something following from the rest, which the kind's setters keep in step. A shape made from properties written somewhere else, `registry.shape(_:properties:)`, or given some of its own that way, `registry.shape(_:setting:)` (the command line's `draw`), goes through `derive(_:)` first, so it's as its setters would have left it; a board read (a shape is as saved), a paste, and what a person does don't. | Schemas (a card's height, from its description; `draw`'s `size:` still wins), StickyNotes (a note's height, from its text) |
| `CustomSkeleton` | Drawn more simply zoomed out. `renderSkeleton` draws in `render`'s place while the canvas draws [skeletons](#skeletons) (the camera's zoom under `editor.skeletonZoom`, 35%), but for the shape being edited: its fills, and bars where its text would be (`context.fillSkeletonText`, each as long as its text's columns, `SkeletonText`), never text, shadows or pictures of its own, cheaply: the shape, its kept geometry and `context.zoom`, and what its plugin already keeps of the shape if it's there, never parsing or laying out text; a picture only through `RenderContext` (a subboard's board preview). Its outline there (selected, hovered, the hint) is its kept geometry's, right for a skeleton that fills its geometry or differs from a rect only by corners rounded a pixel or two, unless it adopts `CustomSkeletonOutline`; a shape a few pixels across is outlined by its bounds. Without it a kind is the default skeleton, its geometry in one gray (`context.drawSkeleton(of:color:)`). | StickyNotes (its yellow, its text greeked), Subboards (fills, a title bar, its preview), Schemas (square, with an edge, so outlined by its frame, its description greeked as a note's text), Arrows (its arc and heads), Rectangles (its teal, one fill), Polylines (the default in its indigo) |
| `CustomSkeletonOutline` | A `CustomSkeleton` outlined its own way while skeletons are drawn (selected, hovered, the hint): `skeletonIndicatorPath(of:in:)`, what `renderSkeleton` draws, so the outline and the skeleton agree, made from the shape and its kept geometry, since ⌘A zoomed out asks it of every shape of the kind in view each frame; nil for its kept geometry's. Found once per kind (`registry.skeletonOutlines`), so no other kind's shape is asked; never asked for a shape a few pixels across, outlined by its bounds. | Arrows (the arc, where its kept geometry is three points) |
| `PaintOrderAnchored` | Painted just above another shape, whatever its place in the document. The anchor follows from the shape's own props and the document's order, since the paint order is kept until one of those changes. | Arrows (above the shapes they join) |
| `BoardOwning` | Each shape of the kind owns a board, a subboard, which the file keeps under the shape's id, never in its props (`CanvasFile`, `BoardID(owner:)`). Nothing to implement: deleting a shape takes its board and every board under it, a copy takes what it holds, a file saves every board ([format 4](#boards-on-disk)), and `editor.showBoard` shows one; Boards' `x.opensBoard(placeholder:systemImage:)` opens it. Its schema is marked `x-canvas-board`. [Boards in a file](#boards-in-a-file). | [Subboards](#subboards)' `Subboard`; CanvasTesting's `Pocket` |
| `ShapeReferencing` | Props bound to other shapes: every kind whose props are adopts it, or it stays bound to a shape once it's gone. `remappingReferences(of:_:in:)` passes each through a map: bound to the shape it gives, or, for nil, let go of where it's drawn. Deleting a shape asks it of every shape bound to it (after `willDelete` handlers, before anything's removed), and copying asks it of each copy (`record.remappingReferences(_:in:)`). It returns nil when it can't let go of a shape it can't find: a deletion leaves it as it was, and a copy leaves it out. These are bindings, which must be on the board; a name that may outlive its shape (a mention) is a value instead, [`ShapeNaming`](#values-that-name-shapes). | Arrows (an end lets go where it's drawn, keeping the curve; a copy stays bound to the copies of its shapes); CanvasTesting's `Tag` |

The rule of thumb: behavior intrinsic to a kind is a capability; behavior anyone can add, to any
kind, from any plugin, is an extension point. What a kind shows in the detail panel is an extension
point, not a capability: the kind's own plugin, a horizontal it opts into, and a bridge can all add
to it.

An editing view's `EditContext` is its way back into the editor: `update` changes the shape in a
transaction, and `end()` ends editing. `shape` is the shape as it is now, observed as the document
is, for what something other than typing writes while it's edited (a language model's answer: a
schema card's description). `service(_:)` lends it the editor's services (a completion list's
candidates, the sync a schema card's editor follows), as the detail panel's, the table of contents'
and adornments' contexts do. Services hear editing end, however it ends (Escape, a click elsewhere,
another shape edited, another board shown, an undo), what it wrote committed
(`EditorService.editingDidEnd`), its step closed unless what ended it is an action still under way
(an undo about to apply a step, a command, a draw, a file put in place), so a service that answers
it waits a turn (`editor.scheduler`): a schema card's sync takes its description as done then.
`keepInView(_:)` brings a rect of the view (in its coordinates: world units, the shape's box at
their origin) into the part of the canvas the host leaves clear, 16 points in from its edges,
panning the camera at once by as little as it takes, with no zoom and no undo step: the canvas
scrolls no text of its own, so a note's editor keeps its caret in view this way as the note grows
past the window's bottom with what's typed, or an arrow key moves the caret out of view.
`startPoint` is where the press that began editing was, in world units, when whatever began it said
so (`editor.beginEditing(id, at: point, clickCount:)`), and `startClickCount` how many clicks it
was, for the view to put its selection there as a text view would (the character pressed, or the
word for a double-click); the editor keeps them as `editingStartPoint` and `editingStartClickCount`
while editing lasts. Selection's double-click passes its press and its count (`open(id, at:clickCount:)`),
and a click on the only selected shape of an `Editable` kind edits it from the release (tldraw's; the
press waits for the drag threshold, as a face's does, so a drag still moves it; not a read-only
one, which the click only selects), each only for a press on the shape itself: on what's drawn for
it outside it (a title's pill, `DecorationHits`), which isn't in its text, a double-click passes no
point and a click doesn't edit. The click that brings the window forward doesn't edit either
(`Pointer.activatesWindow`, from the host's `acceptsFirstMouse`). Return and a placement say
nothing, and the view chooses, as it always has. A note too short for its text as editing begins
(saved before notes grew with it, or drawn with a `size:`) grows to it then, in the editing's step.

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
  else), says whether the stack changed, and the boards it took out of the file or brought in
  (`boardsRemoved`, `boardsAdded`: [Boards in a file](#the-editor-and-the-file)), or changed while another was shown (`boardsChanged`:
  Delete Hidden Shapes, undoing it, and `transact(on:)`; `boardsReached` is all three), with the
  shapes it touched on them (`elsewhere`), and whether an agent made it (`byAgent`, which the
  transaction says: `transaction.byAgent`). Transactions don't nest. A body that throws commits
  nothing, whatever it changed first: services hear of no change and no refusal, the board isn't
  edited, no undo step opens (what there was to redo stays), and the error comes out of `transact`
  (untyped: catch it and cast), so work that must happen whole or not at all throws to leave, as
  [`canvas draw`](#draw) does. A frame that isn't finite never gets in: such an insert or update is dropped, since a board
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
  minimap drawn too, and a frame zoomed out to fit the board (at 10,000, as far as the 10% zoom
  goes), where they're [skeletons](#skeletons), and the table of contents' rows after a commit to a
  millisecond. The editor also keeps the bounds of every shape, and where each commit moved or
  reshaped shapes (its damage: where the shapes it touched were and are, with every shape whose
  geometry followed them), for a picture of the whole board kept from frame to frame, the
  minimap's, which redraws only that. Damage says where shapes are, not which is on top: a restack names the shapes it
  moved in the stack, not one it carried along above its anchor. It's host API (`shapeBounds`,
  `damageMark`, `damage(since:)`, and `outlines`, what the canvas outlines), as the minimap is
  the host's.
- **Drawing**, back to front: background and the dot grid (`DotGrid`: tiles of dots filled once,
  copied at whole device pixels, kept while the camera stays); shapes in paint order (culled by extent: those
  more than 40 world units out of view don't draw, so a shadow just out of view shows at its edge,
  a pad grown by the farthest any shape is drawn from where it is, so one shaken into view shows,
  and a shape with no outline always does), each where it's drawn
  ([`setDrawingOffset`](#the-cores-part-drawing-offsets): a shaking shape, away from where it is,
  with its outline), in full or, zoomed out, as its [skeleton](#skeletons); every plugin's outlines
  (`registrar.outlines`: selection, the box around several; none while the session
  `hidesOutlines`) and the hint, in one pass at a constant screen width, over the faint ones
  (`Outlines.faintShapes`: the hover), drawn first, wider and lighter, each asked for its path and
  stroked only if its shape's kept extent meets the area the shapes were drawn for (a plugin's rects
  too; zoomed out, a skeleton's outline, and a rect filled as a ring: [Skeletons](#skeletons));
  world overlays; the running session's `draw(in:)` (the marquee, Snapping's guides); view overlays
  (Selection's handles first). Each shape, overlay and session draws with a fresh graphics state.
  Sizes meant as view points are divided by `zoom` in world space. So outlines cost what's in view
  in strokes, and each outlined shape a look at its kept extent a frame, with nothing copied or
  allocated: `editor.outlines` hands the first source's list (⌘A's, every shape) over as it is, and
  leaves out a faint shape outlined in full without a set of the whole selection; a pan works
  [Selection](#selection)'s box around them out again too, a pass over their kept bounds. With all
  10,000 selected and none in view, a frame took about half a millisecond more than with none
  selected (0.56 ms at 100%, 0.62 at 10%, as measured; `./build.sh bench` holds it to 1 ms).
- **The camera** is `editor.camera`, which anyone may set; setting it stops any camera motion
  running. `editor.animateCamera(to:duration:)` moves it there, eased (tldraw's cubic), a frame
  every 16 ms, and `Camera(fitting:in:inset:maxZoom:)` (Geometry) makes one that shows a rect, in
  a view's size or a rect of it.
  `editor.cameraTarget` is where an animation is headed while it runs, else the camera: what to
  remember a view as mid-motion (Selection's steps back do).
  `editor.viewportSize` is the view's size in view points, zero until it has one, and
  `editor.unobscuredViewport` the part of it nothing the host puts over the canvas covers (the view
  less `coveredTop`, host API, how far down the host's views reach on a board: the path's pill
  inside a subboard, `BoardPath.coveredHeight(on:)`, which the app hands `BoardConfiguration`), what
  a fit fits shapes into: a board's first visit, Zoom to Fit, Selection's `reveal`, and `canvas
  draw`'s `--reveal`, whose `view` is that part of it too.
- **Zooming** is the core's commands, which View's items and the toolbar's zoom menu run (through
  the board's window controller, dimmed while they can't run) and Keyboard gives keys: `.zoomIn`
  and `.zoomOut` (⌘= and ⌘-) go to the next of the stops (`Camera.zoomStops`: 10, 25, 50, 100,
  200, 400 and 800%) past the zoom where the camera's headed, around the view's center, dimmed at
  the last; `.zoomToActualSize` (⌘0) goes to 100%, dimmed there; `.zoomToFit` (⇧1, tldraw's) fits
  every shape of the board shown into view with a first visit's margin, as close as the zoom goes,
  dimmed on an empty board. Each eases the camera over 320 ms (tldraw's animationMediumMs), from
  where it's headed, so pressing again before it lands goes on from there. `editor.zoomPercentage`
  is that zoom in whole percent, observed apart from `camera` and set only when it changes: the
  toolbar's zoom menu is titled with it ("100%"), so it redraws as the zoom changes, never as the
  camera pans. `.zoomToSelection` (⇧2) is Selection's.
- **The view.** `CanvasView` (CanvasUI) is the only AppKit in the loop. It converts events, reports
  its size, hosts the editing view over its shape, hands AppKit the menu for a secondary click, and draws the editor, all through the editor's `@_spi(Host)`
  API. It also hosts the minimap, in its bottom-left corner (`showsMinimap`; View › Show Minimap):
  every shape as a silhouette of its geometry, the part of the board the canvas shows outlined,
  and the selection in the accent color. It shows the board shown: on another board it starts a
  picture afresh (never over the old board's), and back on a board whose picture it kept, it shows
  that one at once. On a board with nothing to show (`shapeBounds` null) it's hidden, and the
  corner is the canvas's, with View › Show Minimap still on; it fades in with the first shape (a
  first shape placed under it by a press, or edited as it's placed, isn't covered as it arrives:
  the minimap waits for the press and the editing to end), and on another board shows or hides at
  once. It moves the camera as tldraw's minimap does, and knows
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

## Skeletons

Zoomed out over a big board, thousands of shapes are in view and nothing on them reads: below 35%
a note's 16-point text is under 6 points on screen, texture rather than words, yet drawing it, the
shadows and the pills is most of such a frame. So there the canvas draws each shape as its
**skeleton**: what the shape is and where, less than the real view, its fills and bars where its
text would be, never text, shadows or pictures of its own. Zoomed back in past the level, each
shape is itself again. At 10,000 shapes zoomed out as far as the zoom goes (10%, some 1,700 in
view), the first frame took 166.9 ms before skeletons, and each after 89.1; with them, and
[adornments](#the-label) drawn blank too, 13.4 and 11.2 (at 1,000 shapes, all in view at 11%, 96.9
and 50.0 before, 9.2 and 7.8 after).

- **One level for the canvas.** `editor.drawsSkeletons` is true while the camera's zoom is under
  `editor.skeletonZoom`, 35%. It's the zoom's, frame by frame, with no hysteresis or debounce
  ([not built yet](#not-built-yet)). The shape being edited is drawn in full whatever the zoom,
  since its editing view is over it (`editor.drawsSkeleton(of:)` says whether one shape is a
  skeleton now), and a frame decides once (`OverlayContext.drawsSkeletons`, and its
  `drawsSkeleton(of:)`). What an overlay draws, or hit testing finds, of a shape's content goes by
  the shape's own level (`drawsSkeleton(of:)`), so what's shown and what answers the pointer agree,
  and the shape being edited keeps its faces and its adornments' text: Selection's
  [faces](#faces-clickable-parts-of-a-shape), Adornments' [labels](#the-label). A shape's
  geometry isn't told the level (`ShapeContext` has no `drawsSkeletons`, and `skeletonZoom` is host
  API), so hit testing, the marquee, arrows' ends, snapping and the minimap go by each shape as they
  always did, and Ports' dots show from 25% as ever, over skeletons too.
- **The host's switch.** `skeletonZoom` is host API (`@_spi(Host)`), so no plugin moves the level or
  reads the number. 0 draws every shape in full at every zoom, for a test held to pictures drawn
  before there were skeletons ([the POC's renders](#testing-plugins)) or about what a shape draws in
  full far out; a value above 1 draws skeletons at 100%, for a test module that can't make a
  `Camera` (it has no Geometry). Setting it redraws, when it changes.
- **The default**, for a kind without a skeleton of its own, is its geometry as the index keeps it,
  drawn as a rough picture of the board draws it (`context.drawSkeleton(of:color:)`, on
  `RenderContext`): a closed outline filled, an open one stroked a view point wide with round caps,
  in one neutral gray (a board preview's, on the light canvas; as far from the dark canvas in the
  dark), with no shadow and nothing inside. It follows [Silhouettes](#the-cores-part-board-previews)'
  rule in device pixels: under 4 pixels both ways a shape is its bounds (a line from its first point
  to its last, if it's open), and under one, the whole device pixel its middle is in, as the
  minimap's silhouettes are, so a far-off shape still shows wherever it lies (a square a pixel wide
  around its middle would be spread over as many as four at a quarter each). A shape with no outline
  (nothing drawn) draws nothing.

A kind's own is `CustomSkeleton` ([Capabilities](#capabilities)): `renderSkeleton` draws in the
default's place, given the `RenderContext` a render gets. Rectangles' fills its frame in its teal
([your first plugin](#your-first-plugin)); Polylines' is the default in a color of its own, so a
line drawn by hand still tells from an arrow:

```swift
extension PolylineDefinition: CustomSkeleton {
    func renderSkeleton(_ shape: ShapeRecord<Polyline>, in context: RenderContext) {
        guard let geometry = context.shapes.geometry(of: shape.id) else { return }   // kept, never worked out again
        context.drawSkeleton(of: geometry, color: PolylineStyle.color)
    }
}
```

The registry finds each kind's once (`registry.customSkeletons`), so a frame asks a shape nothing
but its kind. `drawSkeleton` saves and restores the graphics state and paints as `fillPath` does,
so call it with no path of your own under way.

- **Keep it cheap.** Zoomed out a frame draws thousands, so a skeleton is a few fills that cost
  about the same whatever the shape holds. It reads the shape, its kept geometry
  (`context.shapes.geometry(of:)`) and `context.zoom`, never anything that parses or lays out text:
  a line's bar is as long as its columns at an average advance (`SkeletonText`, below), not as its
  measured width, and its text is read only as far as the shape shows it (a note's paragraph until
  it fills the lines left); what a plugin keeps of a shape it uses only if it's there, making
  nothing. A picture it may still draw, as the render would, through `RenderContext` (a
  subboard's board preview). A plugin can't read `skeletonZoom`, so a kind that simplifies further,
  farther out, goes by `context.zoom`.
- **Greeked text**: `context.fillSkeletonText(bars)` fills the rects where text would be (world
  units, a line's worth each) in one fill of the canvas's text-bar color, a translucent dark (black
  at 20%, 26% in the dark) that takes the hue of the light body under it, so every kind's greeked
  text looks alike, and overlapping bars are no darker than one. It takes any `Sequence<CGRect>`, so
  a kind hands its bars over as it works them out, with no array per shape per frame: a
  paragraph's lines through the core's `SkeletonTextBars` (a note's text and a schema card's
  description: `SkeletonTextBars(text, in: box, metrics:)` for plain text, or over a kind's own runs,
  each a `SkeletonTextRunConvertible`, text or something set inline as wide as some columns, a
  mention's pill), counted as a note's lines are ([a vertical plugin](#a-vertical-plugin)).
- **How long greeked text is**, without laying it out:
  [`SkeletonText.columns(of:)`](../Sources/Canvas/Rendering/SkeletonText.swift), the core's, pure,
  counts it in columns, a narrow character's width each, as a terminal does (Markus Kuhn's
  `wcwidth`, approximated by the Unicode blocks that hold most of each): 2 for a character set a
  full em wide (East Asian Wide and Fullwidth: CJK, kana, Hangul, fullwidth forms) or drawn as an
  emoji, 0 for one drawn on another or not at all (combining marks, Hangul's trailing jamo,
  variation selectors, skin tones, zero-width spaces and joiners, direction marks), else 1, a
  regional indicator too (a flag is two); and a scalar a zero-width joiner joins to the one before
  it counts nothing, since the sequence draws one emoji (a family is two columns). One pass over the
  text's UTF-8, a byte at a time while it's ASCII. A bar is its columns at an average narrow
  advance: a note's lines, a schema card's description and a subboard's title at 0.52 em a column
  (calibrated against string drawing, `SkeletonTextMetrics.systemFontColumn`), a blank adornment's
  at an advance measured once from a sample. So every kind's bars count alike, and text in Japanese or in emoji is about as
  long greeked as in full, where a column a character would make it half. A script set wider or
  narrower than two columns' 1.04 em is off by the difference: in a subboard's 15-point title,
  Hangul measured about 0.85 em a character and emoji about 1.3.
- **Its outline** (selected, hovered, the hint) is its skeleton's, not its `indicatorPath`: its
  kind's own if the kind adopts `CustomSkeletonOutline` (`skeletonIndicatorPath(of:in:)`, nil for
  its kept geometry's), else its kept geometry's outline, the default skeleton's; the shape being
  edited keeps its own. The registry finds the kinds that adopt it once
  (`registry.skeletonOutlines`), so no other kind's shape is asked. ⌘A zoomed out outlines every
  shape in view each frame, and stroking a path costs far more than filling one, so there a rect
  (most shapes' geometry, and a plugin's rects, the box around several) is filled as a ring, what
  the stroke would paint but for its square corners; the rest is stroked, round. A shape a few
  pixels across is outlined by its bounds, as its default skeleton is drawn, and isn't asked its
  `skeletonIndicatorPath`. A translucent color (the hover's faint outline) with both rings and
  strokes goes into a layer, so it's no darker where they meet. So `skeletonIndicatorPath` costs
  what the skeleton does, made from the shape and its kept geometry; a kind whose skeleton fills its
  geometry or differs from a rect only by corners rounded a pixel or two (notes, cards, subboards)
  leaves `CustomSkeletonOutline` out, and its ring costs less. An arrow's kept geometry is only
  three points, so it adopts it, and its outline is its arc. The rings took ⌘A's outlines at 10,000
  shapes zoomed out from about 8.1 ms to 4.2, as measured; a pan's frame with all 10,000 selected
  measured 14.4 ms at 10% and 9.4 at 100%, against 11.2 and 7.7 with none selected, each shape
  outlined out of view costing a look at its kept extent
  ([drawing](#the-editor-the-document-and-drawing)).
- **Hearing the level change**: `EditorService.drawsSkeletonsDidChange(in:)`, when
  `drawsSkeletons` changes, and only then: the camera's zoom across the level (a pinch, a zoom
  command; a pinch changes the camera on every event, and services hear only the crossing), the
  host moving the level across the zoom, or a board shown with its camera at the other level, heard
  after `boardDidChange`. Never as editing begins or ends: the shape being edited draws in full
  either way. A pointer held still says nothing, so a service whose hit testing goes by what a
  shape shows lets go here of what the level doesn't show now: Selection looks again at what the
  pointer rests on, buttons first, as a move does, so a button that comes or goes with the level (a
  blank label's shorter or longer reach) takes or gives up the hover without its plugin saying so;
  Adornments lets go of the faces it measured as skeletons start, and looks for nothing itself, its
  layouts answering at the new level whichever service hears first.
- **Batch what's drawn per shape**, in an overlay too, since zoomed out a frame draws it thousands
  of times: Core Graphics fills many rects, or lines, in one path for a fraction of what filling
  each alone costs, while a path of many curves costs more than each filled alone. So Adornments
  flattens its blank capsules' ends to chords before it fills a run as one path, and Validation, as
  the core's outlines do, fills square-cornered rings, where rounded ones stroked together cost ten
  times what each stroked alone does. Keep the order where it shows: a run of one look at a time,
  in paint order, so what's over what doesn't change. And make nothing per shape a frame, no array
  or boxed value: the core builds its rings and lines point by point, and Adornments lays each
  shape's labels out into one buffer a frame.

What each shipped plugin shows zoomed out is in its own section: a [note](#a-vertical-plugin) (its
yellow, its text greeked, and no [mention text](#drawing) or [faces](#on-the-canvas-faces)), a
[subboard](#subboards) (fills, a title bar and its preview), a [schema card](#schema-cards) (white
with a light gray edge, and its description greeked as a note's text is), an [arrow](#a-shape-without-a-frame)
(its arc and heads), a [rectangle](#your-first-plugin) and a [line](#a-shape-without-a-frame);
[faces](#faces-clickable-parts-of-a-shape) (none on a skeleton), [adornments](#the-label) (blank
and pale on a skeleton: a title's [pill](#a-horizontal-plugin) and a [lock](#locking)'s chip), and
[Validation](#a-horizontal-plugin)'s outlines (rings).

## Boards in a file

A file holds a tree of boards: the root, and a board for each shape of a kind that owns one, a
subboard. Owning a board is a capability, `BoardOwning`, with nothing to implement: the core holds
the boards, saves them, takes them out and brings them in with their owners, and shows one at a
time;
[Boards](#boards) gets you around them, whatever kind owns them; and [Subboards](#subboards) is the
shipped kind, a card that opens onto its board.

- **The file is a value.** `CanvasFile` is the root board (`root`, a `CanvasDocument`) and
  `children`, a board for each owner, keyed by the owner's `ShapeID`. A board is named by a
  `BoardID`: `.root`, or `BoardID(owner:)`, written "root" or the owner's id. Keying a board by its
  owner makes the tree a function: a board's parent is whichever board holds its owner
  (`parent(of:)`, `path(to:)`, root first), so a board has one owner, deleting the owner can take
  its board, and a copy (a new id) has a board of its own; nothing done in the app can make a loop
  or give two shapes one board, and only a file edited by hand can have them, which reading keeps
  and reports ([Boards on disk](#boards-on-disk)). Shape ids are unique across the file
  (`board(containing:)`, `record(_:)`). A board with no shapes isn't kept, so placing an owner
  makes nothing but the shape. Walks over the tree (`path(to:)`, `subtree(ownedBy:)`) are loops that
  stop at a board they've met.
- **Each board has a revision** (`file.revision(of:)`) that changes with its shapes and never comes
  back (a file put in place keeps it only for a board whose shapes are as they were). What's kept
  about a board (its index, its rows, its issues, its locks, its preview) is taken back only while
  its revision is the one it was kept at, so whatever writes a board, shown or not (an undo, a
  model's answer, someday an agent or sync), nothing stale is used.
- **The board is the owner's, never its props'.** A kind's props don't name its board, and its
  schema is marked `x-canvas-board`.

The smallest kind that owns boards is CanvasTesting's pocket, which core and horizontal tests nest
boards with ([Pockets.swift](../Tests/CanvasTesting/Pockets.swift)):

```swift
public struct Pocket: BoxShapeProps {
    public static let kind: ShapeKind = "pocket"
    public static let properties = Properties<Pocket> { Property("frame", \.frame).required() }
    public var frame: CGRect
}

struct PocketDefinition {}

extension PocketDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Pocket>, in context: RenderContext) {
        context.fillWithShadow(CGPath(rect: shape.frame, transform: nil), .systemGray)
    }
}

extension PocketDefinition: BoardOwning {}          // each pocket owns a board
```

That's all: a pocket deleted takes its board and every board under it, a pocket copied takes what
it holds, the file saves them, and `editor.showBoard(BoardID(owner: pocket))` shows one. A
double-click, Return and ⌘↓ opening it, Open in its menu and panel, ⌘↑ back up and a name on the
path come from one more line, Boards' `x.opensBoard(placeholder:systemImage:)`.

### The editor and the file

One editor holds a whole file and shows one board of it, so every host that has `let editor` (a
window, the command line's server, a test's harness) keeps it. The editor holds every board
(`editor.file`) and shows one (`editor.board`; the root until another is shown, below):
`document` is that board, what every tool, drawing, hit test and service works on, so read what's
shown from `document`, and never list shapes from `file`. `editor.contents(of: board)` is any
board's shapes, and `editor.owner(of:)` the shape that owns it, wherever it is.

A transaction is on the board shown (`transaction.board`) and never holds the file: it reads it
through the editor, so a commit, a drag's every event, costs what it changed, not the file. Two
things reach past it, both in the one commit:

- **Deleting a shape takes the board it owns, and every board under that** (the cascade), whatever
  its kind, since the file keeps a board by its owner's id (`ChangeSet.boardsRemoved`), with no
  handlers run inside them, as nothing outside a board is bound to a shape in it. It's one undo
  step, and undoing it puts back every board under the shape, every id as it was. An owner whose
  board, or a board under it, holds a read-only shape (a locked one) isn't deleted, and shakes
  ([read-only shapes](#the-cores-part-read-only-shapes)).
- **A shape can go in with its boards**, `transaction.insert(record, contents:)`, its board under
  its id and those below under theirs (a paste; `boardsAdded`): a board it doesn't reach, or whose
  owner can't go in (a frame that isn't finite, deleted in the same transaction), is left out.
  `transaction.contents(ofBoardOwnedBy:)` is a board as the transaction leaves it.

Shape ids are unique across the file: an insert's must be on no board (unless the transaction
deleted it from its own). An undo step holds the boards a commit takes out or brings in, whole, as
they were before the step and are after it ([Undo](#undo)).

The host's whole-file operations are `replaceFile(with:showing:)`, `replaceDocument(with:)` (a file
of that board alone) and `discardKeptAside(shapes:boards:)`. `replaceFile` is opening and
reverting: it cancels a running session, ends editing and camera motion, fills in defaults on every
board, gives every board a new revision (but one whose shapes are as they were: a reload after a
change on disk keeps the previews of boards it didn't change) and clears the undo history, so it
doesn't edit the file, nor does what the session, services or an editing view commit as they end,
which goes to the file replaced. It stays on the board shown if the new file can show it, else goes
to the nearest board above it, or the root, unless `showing:` names one it can show, as a switch
does (and `CanvasEditor(registry:file:showing:)` opens on one). `discardKeptAside` is Delete Hidden
Shapes: shapes kept aside wherever they are, with their boards, and the boards kept; one undo step,
"Delete Hidden Shapes", whatever boards it took them from, whose undo puts back the file as it was.

### Showing a board

`editor.showBoard(board)` shows another board of the file: it becomes `document`, and
`editor.boardPath` is the boards from the root down to it. It isn't an edit, nor an undo step (it
closes the step under way), and it can't happen mid-press: it returns false while a session runs,
and for a board `canShow` refuses (one whose owners, from the root down, aren't all in the file,
each of a `BoardOwning` kind and none kept aside; the board itself may have no shapes; the rule is
the file's, `file.canShow(_:boardOwningKinds:)`, nonisolated, so what reads a file off the main
actor, a query, draws the same line). In order:

1. Services hear `boardWillChange(from:to:)` while the old board is still shown: save what's its (a
   draft, state kept per board).
2. Editing ends, so an editing view that saves as it closes saves on its own board; the default
   tool comes back (an armed tool doesn't carry over; a tool that wasn't in the middle of something
   isn't cancelled); camera motion stops, and the old board keeps the camera it was headed to.
3. The new board takes back the geometry, paint order, bounds and damage the editor worked out for
   it, if its revision hasn't changed since (for the 8 boards shown last, those on the path kept
   longest), and otherwise works them out afresh; `revision` bumps once; and the camera is the one
   the board was left with, else the one the host remembers (`rememberedCameras`, host API, from
   the view memory; `boardCameras` is every board's, to save), else, on a first visit, its shapes
   fitted into view no closer than 100% (into what the host leaves clear of the view on that board,
   `coveredTop`: below the path's pill), else `Camera()`.
4. Services hear `boardDidChange(_ change: BoardChange)`: `from`, `to`, `leftCamera`,
   `isFileReplaced` (a whole file was put in place as it went, `replaceFile`: what a service keeps
   across the file by shape id it takes afresh, since what it keeps by a board's revision is no
   longer taken back anyway), and `changes`, the switch as a commit's change set (every shape of
   one board gone, every shape of the other come, the stack changed; a shape on both, which only a
   file put in place can have, changed), worked out only if something reads it.
5. If the new board's camera draws [skeletons](#skeletons) where the old one's didn't, or the other
   way round, services hear `drawsSkeletonsDidChange`: only now, once they've heard the switch.
6. The host hears `editorBoardDidChange`, and redraws.

**Warm state.** By default a service hears the switch as `documentDidChange(change.changes)`, which
is right for state kept per shape, at the cost of both boards' shapes. A service that keeps state
per board overrides it with a `BoardStash<State>` (kept in `boardWillChange`, taken in
`boardDidChange`, given back only while the board's revision is unchanged, at most 8 boards, the
path's longest), and reads no other service there, since services hear it one by one. A service
that keeps nothing per shape overrides it with nothing. In the shipped plugins, the table of
contents, Validation and Locking keep each board's rows, issues and locked shapes in a stash (the
table of contents drops its stash when a file put in place shows another board and some row reads
other shapes, since that switch doesn't say what the file changed on the boards kept);
Selection makes the board left a step back and lets go of the press, hover and buttons; Boards
makes the path again; Adornments drops its labels (made again only for the shapes a frame draws,
and a label kept would miss an open lock that Locking let go of); the schema cards' sync keeps
every card of the file by id (and takes them afresh when `isFileReplaced`), and Topology's index
and Mentions' resolutions and catalog are the file's, so a switch changes nothing for them (a file
put in place is read afresh); Ports lets go of the
dots it showed; the panel commits a number being typed in `boardWillChange`, and arrows stop aiming
there; and the context menus, the keyboard, the clipboard and the language model keep nothing per
shape. So no shipped service works out the change set (CompositionTests' BoardsTests hold them to
it), and going back to a board shown lately costs the editor, the canvas and the services a frame
(`./build.sh bench`). Not the panel's list: with the table of contents showing, a switch replaces
every row of its `List`, which AppKit sizes one by one, some 120 ms at 1,000 rows and a second at
10,000, however warm the board ([Not built yet](#not-built-yet)).

Damage marks name the index they were taken on (`DamageMark`, `editor.isCurrent`), so a picture kept
for a board (the minimap keeps 8) is current only while the editor kept that board's index, and a
mark from another board's is damage everywhere. Of a kind's definition only its render reads another
board: `context.shapeCount(inBoardOwnedBy:)` and `context.drawBoardPreview(ofBoardOwnedBy:in:)`
([previews](#the-cores-part-board-previews)), and `context.shape(inFile:)`, a shape anywhere in the
file on a board the editor can show (a mention's pill names one, [across
boards](#mentions-across-boards); `editor.shape(inFile:)` outside a render), on `RenderContext`
alone, so geometry and hit tests never depend on another board. The core names the commands
`.openSelection` and `.enclosingBoard` for plugins to claim: Selection claims `.openSelection` (⌘↓;
[opening a shape](#selection)), [Boards](#boards) claims `.enclosingBoard` (⌘↑), and going back
crosses boards.

### Boards that aren't shown

A commit says what it did beyond the board it's on: `ChangeSet.elsewhere` is every shape of the
boards it took or brought, and those it changed on a board it kept (and, for a file put in place
over the board shown, the shapes its other boards don't have as they were). No shape there is the
board shown's, so what a service keeps of the board shown needn't follow them; what reads shapes
anywhere in the file does (a row showing the name of a shape on another board, gone with the board
its owner took).

Two things edit a board that isn't shown: Delete Hidden Shapes (`discardKeptAside`, [the editor
and the file](#the-editor-and-the-file)), which takes shapes kept aside from whatever boards hold
them, and `editor.transact(on: board, "Name") { … }`, for what lands after its board was left (the schema card's sync, whose answer comes back seconds later). On
the board shown it's `transact`; on another, the transaction's `document` is that board's shapes as
the file has them, and its commit changes that board in the file without showing it, as an undo
step of its own made on that board, so undoing it from anywhere shows that board first. A step open
on the board shown (a press, a field typed into) stays open and comes after it. Services hear it as
a commit that changed that board (`boardsChanged`, its shapes in `elsewhere`), the board shown as it
was, and the canvas redraws, so an owner's card on the board shown shows what it holds now. Nothing
shows what it refused (a read-only shape isn't shown to shake), and a transaction that would take
the board shown, or one above it, commits nothing. It returns nil for a board the editor can't
show. Every other change to a board is made while it's shown, or with a shape on the board shown
(a deletion takes the boards under it, a paste brings them).

### Boards across the plugins

Every plugin that reads `document` is local to the board shown with no code of its own: drawing,
hit testing, Select All, the minimap, arrows, Reordering. What the others do with boards is with
each of them:

| Where | Boards |
|---|---|
| [Selection](#selection) | Opening a shape (`ShapeOpening`); Back crosses boards, and showing another board is a step; nothing is selected on arrival; `showBoard(_:selecting:)`; `goTo` goes to a shape on any board. |
| [Boards](#boards) | Opening a kind's boards, ⌘↑, a board's name and symbol, and the path over the canvas. |
| [The table of contents](#whats-listed-and-selecting) | Lists the board shown, keeps each board's rows, and takes its header from its placer (the board's crumb, in the app). A row may read shapes on other boards ([`elsewhere`](#rows-read-from-more-than-their-shape)). |
| [Validation](#a-horizontal-plugin) | Checks the board shown, keeping each board's issues; a board never shown isn't checked, and a rule's lookups (MentionValidation's targets) find shapes there alone. |
| [Locking](#locking) | A shape whose board holds a locked shape isn't deleted; a locked owner is entered as any other. |
| [Mentions](#mentions-across-boards) | A mention names a shape on any board, live and followed there (`goTo`, or `goInto` for a kind followed by opening it: a subboard); who mentions whom (Topology's), what each mentioned shape shows and the `@` picker's catalog are the file's (the board shown's first on a tie), so showing another board reads no mention text; so are the Mentioned In tab's and Show What Mentions' mentioners, the board shown's first. |
| [Topology](#topology) | The file's edges, and containment (a shape's parent is its board's owner), whatever board is shown; showing another board reads nothing. |
| [The clipboard](#the-clipboard) | Copies what a shape holds, all the way down, and pastes the tree with new ids; what a cut took, onto any board, under the ids it had (a move). |
| [Undo](#undo) | One history per file; a step holds every board it reached, and undoing one made on another board shows that board first. |
| [Boards on disk](#boards-on-disk) | Format 4 saves every board, in one flat map; the camera on each board, and the board left open, are remembered per file on this Mac. |
| [The command line](#the-command-line) | Commands work on the board a file's window shows. |

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
| A press on the canvas: from the press to the release, its whole drag (a place, its follow and the editing it begins on the release, a translate, a handle, a lock chip's click) | One. |
| A key on the canvas; a command (`editor.perform`: every menu item's, ⌘Z's and Delete's); `editor.undoHistory.group("Name") { ... }` | One each. These actions nest; the outermost is the step. A key's step takes what its repeats commit while it's held (`KeyStroke.isRepeat`, the same key with the same keys held), until it's let go (`editor.keyUp`, or `keysReleased`: the canvas lost the keyboard) or anything else happens (another key, a press, a commit, `seal()`, undo, a save), so a held arrow key's nudges are one step. |
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
card's sync "Update Schema" and "Update Description", however long after the edit it lands; and
Automation "Draw", a whole `canvas draw` run (a dry run, or a script refused, is none; a run waits
out a press held, `undoHistory.isPressHeld`, whose step would take it in). Name a transaction a
user would think of as one thing, and wrap several in `group` when they're one action the editor
doesn't already see as one.

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
never moves, as in tldraw (a board shown for a step made on it has the camera it was left with).

**What else goes back.** A service whose state belongs with the steps adopts `UndoParticipant`: its
snapshot is taken as a step opens and as it closes, and undoing restores the first, redoing the
second. Selection's is the selection, as tldraw's: undoing Delete brings the shapes back selected,
undoing a move leaves them selected, undoing a paste selects what was before it. The restore is an
ordinary change of the selection, so Go › Back returns to what was selected before the undo; on a
board undo has just shown for its step, the switch and the restore are one step back, as
`showBoard(_:selecting:)` makes them, so Go › Back returns to the board Undo was pressed on.
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
that isn't a board's (the color panel a color well opens, whose picks are panel writes), but not
in a board's child window (the `@` picker beside a panel's text, whose pick is part of the typing).

**Counting and saving** is the host's: `BoardDocument` has no undo manager, and counts its changes
by the history's events as they happen (`undoHistory.didChange`, host API: a step began, came to
nothing, was undone or redone), so undoing to what was saved reads unedited, and past it edited. A
save closes the open step (`breakStep`) before NSDocument takes the change count it marks saved, so
undo goes back to exactly what was saved, and a step that comes to nothing as it closes leaves the
board unedited; a periodic autosave during a press, or while a key is held whose repeats are one
step (`undoHistory.isKeyHolding`, host API: a held arrow key's nudges), waits for its release, and
is scheduled again then ([Boards on disk](#boards-on-disk)). A new document, a board opened or reverted
(`replaceFile`) has nothing to undo.

**Boards.** A file has one history, whichever of its boards is shown. A step is made on the board
shown as it opens (`DocumentDelta.board`): showing another board closes it, and isn't a step itself,
so entering and leaving boards are never undone. Undoing or redoing a step made on another board
shows that board first (`showBoard`, as any switch: services hear it, and the camera is the one the
board was left with), then applies the step there and gives participants back what they kept, so
the selection comes back on its own board, and one Go › Back returns to the board Undo was pressed on
(the switch and the selection given back are one step).
That board can always be shown: steps come back last in, first out, and every change to the file is
a step's, so the file is as the step left it; `canUndo` and `canRedo` say no only while a press runs,
as a switch can't happen then. What a service commits as a board is left (the panel commits a number
being typed) is a step of its own on the board left, newer than the one Undo was going for: that
Undo stops once the step's board is shown, and the next undoes the commit, on its board. A Redo
from there shows the step's board too, and stops there with nothing left to redo: the commit is an
edit like any other, which leaves nothing undone to redo. A commit on a board that isn't shown
(`transact(on:)`: a sync's answer landing after its board was left) is a step of its own made on
that board, pushed at once, under whatever step is open on the board shown: undoing it from anywhere
shows its board, like any step made there.

**A step is all it did to the file.** Besides its board's records, it holds every other board it
reached, whole, as it was before the step and is after it (`DocumentDelta.boards`, copies that cost
nothing, since a board is a value): the boards a deletion took with the shapes that owned them,
every board under them; those a paste brought with its shapes (`insert(_:contents:)`); and those
Delete Hidden Shapes deleted from, with the entries of the file it took that didn't read as boards
(`unreadableBoards`). So undoing Delete of a shape that owns a board brings the shape back with
everything under it, every id as it was, in one step, and redo takes it all again; undoing a paste
takes its boards out with its shapes, leaving no board without its owner, and redo puts back the
same ids. Services hear the boards in the change set (`boardsAdded`, `boardsRemoved`,
`boardsChanged`), and each board the step changes gets a new revision, so nothing kept about one
(the editor's index, the table of contents' rows, validation's issues, the minimap's picture) is
taken for it: entering a board undo put back works it out afresh. `DocumentDelta` is the one type
that holds records before and after (`CanvasFile.apply` puts one in place), and
`CanvasEditor.apply(_:restoring:)` the one place a step is applied; agents and sync can reuse them,
with who made the change.

## Boards on disk

A board is a file (`.canvasboard`; `.board` is Freeform's), with every board inside it, opened and
autosaved in place by `BoardDocument` (CanvasUI, an `NSDocument`). `BoardCodec` (Canvas) reads and writes it: JSON, sorted and
pretty-printed, so a board diffs cleanly.

```json
{
  "format" : 3,
  "shapes" : [
    { "added" : { "title" : "Groceries" }, "id" : "…", "index" : "a0", "kind" : "sticky-note", "props" : { "frame" : [[80, 80], [200, 200]], "text" : "…" } },
    { "added" : { "locked" : true }, "id" : "…", "index" : "a1", "kind" : "sticky-note", "meta" : { "clipboard" : { "copiedFrom" : { "shape" : "…" } } }, "props" : { … } },
    { "id" : "…", "index" : "a2", "kept" : { "confetti" : { "v" : 0, "value" : { "velocity" : 240 } } }, "kind" : "rectangle", "props" : { … } }
  ],
  "versions" : { "added" : { "locked" : 0, "title" : 0 }, "kinds" : { "rectangle" : 0, "sticky-note" : 3 } }
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
in it: they're remembered per file on this Mac, so panning never marks a board edited. So are the
camera on each of a file's boards and the board left open (`BoardViewMemory.View`'s `board` and
`boards`, read with `decodeIfPresent`, so a view remembered before files had boards is the root's;
saved for the boards the file can still show: the one shown and those above it, then those shown
most lately, 50 in all, in `recent`'s order, the one shown last first, which `editor.boardsLeft`
and the last session's `recent` give): the file opens on that board, if it can still show
it, as a file put in place there (`replaceFile(with:showing:)`), so it isn't a step back, nor an
edit; each board has its camera as it was left (`rememberedCameras`).

**Edited, and saved.** A board is edited as a step begins, and counted back as a step comes to
nothing or is undone ([Undo](#undo)): `BoardDocument` makes NSDocument's own change-count calls as
the history's events come, at once, rather than through an undo manager (it has none). So undoing
to what was saved reads unedited, undoing past it edited, and redoing edited again. Every save
closes the step under way, so what was saved is a step boundary, and what's typed after it is a
step the save didn't see, which marks the board edited again: a long typing session may split at
an autosave, as TextEdit's does. A periodic autosave that comes during a press (a drag), or while
a key is held whose repeats are one step (an arrow key's nudges), gives way
(`CocoaError.userCancelled`, which NSDocument doesn't show) and runs once the press, or the key, is
let go;
`BoardDocument.snapshot(implicitlyCancellable:)` is what a save writes.

**A kind versions its own props.** Its migrations sit beside `static let kind`, and their count
is the version boards record. The sticky note's steps drop a `checklist` member it kept, hand its
title over to Titles, and make its text mention text:

```swift
public struct StickyNote: BoxShapeProps {
    public static let kind: ShapeKind = "sticky-note"
    /// Append only. The count is the version boards record.
    public static let migrations = [
        // The checklist it kept is dropped.
        PropsMigration("checklist becomes the checklist property") { $0["checklist"] = nil },
        // Titles adds the title to every kind that opts in, once someone names the shape.
        PropsMigration.handOver("title", to: TitleProperty.self),
        // Its text may mention shapes: what would now read as a mention is escaped.
        PropsMigration("text may mention shapes") { props in MentionTextFormat.escapeLookalikesV1(in: &props, "text") },
    ]
    ...
}
```

A step is one of three:

- **`PropsMigration("…") { props in ... }`** rewrites one shape's props as JSON (`JSONObject`), since
  old props may no longer decode.
- **`PropsMigration("…")`**, with no body, is the step for a new member with a default. Boards
  from before it read as the default, but it still takes a version: otherwise an older app would
  read a board this one wrote as its own version, and drop the member when it saved. The version
  also gets its fixture.
- **`PropsMigration.handOver("title", to: TitleProperty.self)`** hands one of the kind's own
  members over to an added property the kind now opts into. Reading an older board moves the
  member's value from `props` to `added`, as the property's value at the version the step names
  (`version:`, the property's version when the step is written; it defaults to 0, so pass it if the
  property already has steps. Pinned, it stays right as the property takes steps of its own), then
  migrates it by the property's history. It's a sticky note's second step, which moves its title
  onto Titles' `TitleProperty`.

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

**A file holds every board.** A file with boards besides the root (`CanvasFile`, the boards shapes
of a [`BoardOwning`](#boards-in-a-file) kind own) is format 4: the root's shapes stay in `shapes`, and
every other board is in `boards`, under its owner's id, as an object with its own `shapes` (records
exactly as the root's, stacking keys per board, `versions` covering them all; any other member a
board comes to have needs a newer format, as a record's new members did, since this app would save
the board without it). The map is flat
whatever the boards' depth, so a file is no deeper than a board is and every walk over it is a loop;
a board with no shapes isn't written, so a file whose other boards have emptied goes back to 3, 2
or 1. `BoardCodec.encode(file)` writes it (`encode(document)` writes a file of that board alone),
and `LoadedBoard.file` is what reading gives (`document` is its root): `BoardDocument` saves
`editor.file` and opens a file with `replaceFile`. An older app refuses format 4 rather than open
the root and save the other boards away.

```json
{
  "boards" : {
    "A1B2…" : { "shapes" : [ { "id" : "B0B0…", "index" : "a0", "kind" : "subboard", "props" : { … } } ] },
    "B0B0…" : { "shapes" : [ { "id" : "…", "index" : "a0", "kind" : "sticky-note", "props" : { … } } ] }
  },
  "format" : 4,
  "shapes" : [ { "added" : { "title" : "Plan" }, "id" : "A1B2…", "index" : "a0", "kind" : "subboard", "props" : { … } } ],
  "versions" : { "added" : { "title" : 0 }, "kinds" : { "sticky-note" : 2, "subboard" : 0 } }
}
```

Reading goes through the boards in tree order with one set of ids: the root, then the boards it
reaches, breadth first, each board's in its shapes' order, then those it doesn't, by key. So a
repeated id is the first holder's, with the board it owns, and a later holder gets a new id and
owns nothing. A board the app can't show is still read, kept and written back, and
`LoadReport.keptBoards` says why (`KeptBoard.Reason`): its owner is kept aside (`ownerKeptAside`:
an app without the kind keeps every board of it), its owner's kind owns none (`ownerNotABoard`), it's
inside a board kept for either (`insideKeptBoard`), going up from it never reaches the root
(`unreachable`: an owner missing from the file, or owners holding each other's boards; kept, never
repaired), or the entry isn't a board or its key isn't an id as the app writes one (`unreadable`,
kept verbatim in `CanvasFile.unreadableBoards` until a board a shape comes to own takes its key;
an entry that can't be kept as it was, a number JSON can't hold in it, stops the file opening).
Shapes and values kept aside say which board they're on (`KeptShape.board`, `KeptValue.board`).

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
shapes the app can use; `keptBoards`, the boards) and what was repaired; the window shows it,
offering to delete the shapes kept aside and the boards kept (`BoardDocument.deleteHiddenShapes`,
through `editor.discardKeptAside`, one undo step) but never to discard a value. Repairs mark the
board edited, so saving keeps them. Only a file that isn't a board, or comes from a newer app,
refuses to open (`BoardReadError`), or one whose `boards` holds an entry that can't be kept as it
was.

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
name and the kind it's for (`ValidationRules → schema-card`); Keyboard's shows the key and what it
does (`shortcut V → tool select`).

It runs once per point that has contributions, in the order of each point's first contribution,
and may read any point's contributions. `ShapeDetails` uses it to refuse two tab types with one
title, which would show as two identical tabs. Had Schemas declared a Board tab of its own
beside the one Boards brings subboards:

```
ShapeDetails: Boards.BoardTab (from subboards) and Schemas.BoardTab (from schemas) are both tabs titled "Board"; share one, or retitle one
```

The hook is generic: the core runs it without knowing what any point checks.

Once built, it's frozen and handed to the editor. The app's list is
`ShippedPlugins.plugins(pasteboard:model:)` in [Composition](../Sources/Composition/ShippedPlugins.swift),
and a test checks it registers.
`registry.report` prints who contributes what: the runtime half of the graph, pinned by a test.

```
core                 tool hand · command undo · command redo · command zoomIn · command zoomOut · command zoomToActualSize · command zoomToFit
keyboard             service KeyboardState · key strokes · key releases · shortcut H → tool hand · shortcut Space → Pan · shortcut ⎋ → Cancel · shortcut ⌘. → Cancel · shortcut ⌘Z → command undo · shortcut ⇧⌘Z → command redo · shortcut ⌘= → command zoomIn · shortcut ⌘- → command zoomOut · shortcut ⌘0 → command zoomToActualSize · shortcut ⇧1 → command zoomToFit
selection            service SelectionState · tool select · shortcut V → tool select · default tool select · outlines · overlay HandlesOverlay · command delete · shortcut ⌫ → command delete · shortcut ⌦ → command delete · command selectAll · shortcut ⌘A → command selectAll · command goBack · shortcut ⌘[ → command goBack · command openSelection · shortcut ⌘↓ → command openSelection · shortcut ↩ → Open Selection · shortcut ⌤ → Open Selection · command zoomToSelection · shortcut ⇧2 → command zoomToSelection · command smartMagnify · shortcut ← → Nudge · shortcut ⇧← → Nudge · shortcut → → Nudge · shortcut ⇧→ → Nudge · shortcut ↑ → Nudge · shortcut ⇧↑ → Nudge · shortcut ↓ → Nudge · shortcut ⇧↓ → Nudge
topology             service TopologyIndex
arrows               shape arrow · label Arrow → arrow · ContentsRows → arrow · service ArrowTargeting · overlay BindingHintsOverlay
sticky-notes         shape sticky-note v3 · tool sticky-note · shortcut N → tool sticky-note · DoubleClickPlacement → sticky-note · property title → sticky-note · ShapeTitles → sticky-note · ContentsTitles → sticky-note · ShapeDetails → sticky-note · ContentsRows → sticky-note · ports note-link → sticky-note · mention text → sticky-note · mentionable → sticky-note · ShapeDetails → sticky-note · channel note-link · edge type note-link
subboards            shape subboard · tool subboard · shortcut B → tool subboard · property title → subboard · ShapeTitles → subboard · ContentsTitles → subboard · board → subboard "Untitled Subboard" · ShapeOpening → subboard · ShapeContextMenus → subboard · ShapeDetails → subboard · mentionable → subboard · ShapeDetails → subboard · ContentsRows → subboard · ShapeDetails → subboard
schemas              service SchemaSync · shape schema-card · tool schema-card · shortcut S → tool schema-card · ValidationRules → schema-card · ShapeTitles → schema-card · ContentsTitles → schema-card · ContentsRows → schema-card · ShapeDetails → schema-card · ports schema-link → schema-card · channel schema-link · edge type schema-link
validation           service ValidationEngine · overlay ValidationOverlay · ValidationRules
adornments           service AdornmentState · overlay AdornmentOverlay · CanvasButtons · DecorationHits
detail-panel         service DetailPanelState
context-menus        service ContextMenuState · secondary-click menu · CanvasContextMenu
table-of-contents    service ContentsState
titles               property title · adornment TitlePill → every shape
mentions             service MentionState · edge type mention · edges → every shape · overlay MentionFrames · ShapeFaces · CanvasContextMenu
board-navigation     service BoardCrumbs · command enclosingBoard · shortcut ⌘↑ → command enclosingBoard
validation-details   DetailStatuses in Issues
validation-contents  ContentsMarks
mention-validation   ValidationRules
clipboard            service ClipboardState · command cut · shortcut ⌘X → command cut · command copy · shortcut ⌘C → command copy · command paste · shortcut ⌘V → command paste · CanvasContextMenu
locking              property locked · property locked → every shape · read-only shapes · service LockState · adornment LockChip → every shape · ContentsMarks · CanvasContextMenu
snapping             service SnapState · translation adjuster
ports                property channel · service PortState · overlay PortOverlay · CanvasButtons
arrow-ports          property channel → arrow · edge type arrow · connector → arrow · edges → arrow · ArrowBindingRules
language-models      service LanguageModelState
automation           command line draw · command line kinds
title-names          draw names
port-edges           draw edges
validation-checks    draw checks
queries              service QueryState · query engine
title-queries        query names
board-queries        query board names
mention-queries      query word :mentions · query word :mentioned-by · query text text/x-canvas-mentions
validation-queries   query word :invalid · query word :warned
selection-queries    query word :selected
query-commands       command line query · command line query-vocabulary
rectangles           shape rectangle · tool rectangle · shortcut R → tool rectangle
polylines            shape polyline · tool polyline · shortcut L → tool polyline
eraser               tool eraser · shortcut E → tool eraser
rectangle-titles     property title → rectangle · ShapeTitles → rectangle · ContentsTitles → rectangle · ShapeDetails → rectangle
reordering           ShapeContextMenus
```

A horizontal's opt-in shows as what it contributes: `note.title()` is the opt-in to the property
titles declares (`property title → sticky-note`), a `ShapeTitles` entry and a `ContentsTitles`
entry (the title naming the row); the `ShapeDetails` entry after them is the note's header, where
it's renamed. `sub.opensBoard(…)` is Boards' entry (`board → subboard "Untitled Subboard"`), then
the `ShapeOpening`, `ShapeContextMenus` and `ShapeDetails` entries it brings: opening, Open, and
the Board tab. `v3` on sticky-note is the version of its props: its steps drop a `checklist`
member it kept, hand its title over, and make its text mention text ("text may mention shapes", which
escapes what would now read as a mention). Validation's `ValidationRules`, for
every kind, is its schema rule ([Checking shapes](#checking-shapes-against-their-schemas)). Locking opts
every kind in itself (`property locked → every shape`), and `read-only shapes` is its rule for the
core. `ports note-link → sticky-note` is a note's ports and `channel note-link` the channel
StickyNotes declares for them, with its edge type (`edge type note-link`); arrow-ports' `connector →
arrow` makes arrows what ports draw, and brings the opt-in before it (`property channel → arrow`),
the family's edge type (`edge type arrow`) and the arrows' edges (`edges → arrow`). `topology` is
the index of them all (`TopologyIndex`), right after Selection, so it hears each commit first. `mention text → sticky-note` and
`mentionable → sticky-note` are Mentions' opt-ins: a note's text shows pills (`note.mentionText`),
and text may mention a note (`note.mentionable`), which brings the `ShapeDetails` entry after it,
the Mentioned In tab. A subboard is mentionable with its tab too (`mentionable → subboard`: called
by its title, and following a mention of one enters it).
`mentions` declares the `mention` edge type and says what mention text carries (`edge type
mention`, `edges → every shape`: every kind it picks, the ones that can hold names), keeps how
each mentioned shape shows (`MentionState`), tells the text it keeps drawn
(`MentionTextMemo`) where each frame ends (`MentionFrames`, an overlay that draws nothing), makes
pills answer clicks (`ShapeFaces`), and puts Show What Mentions in the context menu
(`CanvasContextMenu`); `mention-validation`'s `ValidationRules`, for every kind, is its warnings
about mentions that can't work.
Titles places its pill on every shape whose kind's title shows one (`adornment TitlePill → every shape`),
and Locking its lock; `adornments` lends them their layout and drawing, a canvas button
(`CanvasButtons`) and their hits (`DecorationHits`), and places none of its own. The automation
line is its commands (`command line draw`, `command line kinds`), and the three after it are the
bridges that fill its draw points, one each. `queries` is the query engine's service (`QueryState`,
which hears no commit) and its mark (`query engine`, which `registry.answersQueries` reads); the
five after it fill its points (names, boards' names, and words and a text format, each by what it
adds), and `query-commands` is `canvas query` and `query-vocabulary`. `rectangle-titles` opts
rectangles into Titles' property (`property title → rectangle`) before titling them.

## Testing plugins

Tests are plain executables built on a small macro-free kit (swift-testing's macros don't work with
this toolchain, and there's no XCTest). `./test.sh` builds and runs them all. `TEST_FILTER=substring
./test.sh` runs the matching tests. A test that would open a real menu (which shows on screen, even
from an unshown window) is opt-in: `TEST_UI_MENUS=1 ./test.sh`. There are two: BoardsTests' check of
the path's "…" menu, and CompositionTests' check that AppKit gives a Control-click to the context
menu before `mouseDown`. [Your first plugin](#your-first-plugin) sets up a test target. A test that
selects and drags as a user does installs Keyboard and Selection first
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
  cards into more, like Selection's double-click), so they never depend on a real vertical;
  `TilesPlugin` adds `Tile`, a second kind a tool places (120 × 80, a label and a finish, one of
  two words), for tests that make shapes of more than one kind, and `LinksPlugin` adds `Link`, a
  connection from one shape to another by id, with no box, for tests that connect shapes without
  Arrows; `ChoresPlugin` adds `Chore` (kind `chore`, labelled "Task", no tool), a box with a property of
  every sort a schema has, and the added `Flagged`, for tests that read shapes by their schemas
  (queries). Their tools have no keys (CanvasTesting can't import Keyboard): a test picks one with
  `h.editor.setTool`, or registers a key for it
  (`$0.shortcut("c", forTool: ToolID(placing: Card.kind))`). SelectionTests, ArrowsTests,
  ValidationTests, DetailPanelTests, AdornmentsTests, ClipboardTests, TitlesTests,
  ValidationDetailsTests, ValidationContentsTests, LockingTests, PortsTests, AutomationTests,
  TitleNamesTests, PortEdgesTests, ValidationChecksTests, MentionValidationTests, QueriesTests,
  QueryCommandsTests and the five query bridges' tests import no real vertical (only these fixtures, and local test kinds), which proves those plugins are
  shape-agnostic. ArrowPortsTests import one real vertical, Arrows, and join fixtures with its
  arrows.
- **Names of shapes** without a real kind that holds them: `NamingPlugin()` (CanvasTesting) registers
  `Memo`, whose props name shapes in a struct in a list (`MemoNote`), an optional and a dictionary,
  and which opts into `CitationsProperty`, an added set of names; and `CitingTag`, bound to its
  target (`ShapeReferencing`) and naming another. `Citation` is the leaf, and `Citation.visits`
  counts how often any is walked or renamed, so a test can show something never looks at names (a
  delete). AutomationTests' `Pin` does both too, and a tool places it, so `canvas draw` can write
  ids into it.
- **Boards in a file** without a real kind: `PocketsPlugin` (CanvasTesting) registers `Pocket`, a box
  whose definition is `BoardOwning`, with no tool. It's apart from `FixturesPlugin`, so the reports
  tests pin don't change. `EditorHarness(plugins:file:)` starts an editor on a file of several
  boards, `h.file` is its file, and `h.enter(owner)` shows the board a shape owns; `openingPockets()`
  (in SelectionTests, TableOfContentsTests and CompositionTests) makes pockets open onto their
  boards (`registrar.opens(Pocket.self, …)`), for a double-click, Return or a row. BoardsTests
  open pockets from a bridge (`registrar.opensBoard(Pocket.self, …)`) and a local `Drawer` kind
  through its own sugar, and host `BoardPath` in an `NSHostingView` in an unshown window to click
  its crumbs. SwiftUI draws a borderless button's title itself, so an `NSButton` there has no
  `title`: a test reads the crumbs' titles headlessly (`editor.boardCrumbs`, `layout(rootName:)`)
  and clicks the buttons by position, leading first. "…" is the button over the view its menu is
  placed against (`BoardPath.foldedAnchor`), never among them: its menu is modal on screen, so a
  test reads and chooses from `BoardPath.foldedMenu(_:editor:)` headlessly, and only the one that
  clicks "…" runs with `TEST_UI_MENUS=1` (it reads the menu as it begins tracking and closes it).
  SubboardsTests hold the real kind to it
  all, with Boards, Titles, the panel and the table of contents installed: the card's pixels (the
  title or its placeholder, the count, no pill), and its header typed into beside a `CanvasView`
  in an unshown window. In the app's window, CompositionTests' `NestedWindow` opens a file of
  subboards (`NestedFile`, `Fixtures/files/nested-mentions.v4.json`) in a `BoardDocument`'s own
  window, as the app wires it: `crumbs` are the path's buttons over the canvas, `hit(_:)` what a
  click would land on, and `goItems()` the app's menus with Go's items sent to its controller (an
  unshown window isn't the key window); `SubboardFileTests` hold saving, reopening on the board
  left open, the view memory, revert and Delete Hidden Shapes to files of subboards.
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
- **Skeletons.** A kind's [skeleton](#skeletons) is held against the same editor drawn in full at
  the same zoom, `editor.skeletonZoom = 0` (host API) the control: StickyNotesTests' Note skeleton
  (at 30%, bars within the text's ink rows and about as long, and as long as their columns; a
  Japanese paragraph on the render's lines; a pill as wide as its label says, not as the label as
  text; text typed in the app, bridged, drawing what a Swift string does; a paragraph of a million
  characters drawing, and costing, what one that fills the box does; notes 1e21 tall or wide; no
  shadow; no mention text built, `MentionDrawingCounts`), ArrowsTests' Arrow skeletons (the arc,
  bent either way, not the chord or the two segments, and a selected arrow's outline on it),
  SchemasTests' render tests (no text, the edge, a bar where each line of the description is, as
  long as its columns, a wide character two, an empty card none, the first frame after an edit and
  its undo, cards 1e21 tall or wide, and drawing reading no schema, `schemasRead`). A test module
  without Geometry can't make a `Camera` to zoom out, so it draws skeletons at 100%, `skeletonZoom`
  just over 1, where world units are view points (RectanglesTests, ExamplesTests, SubboardsTests'
  The card zoomed out, which holds the title's bar to the render's title in Latin, Japanese,
  Chinese, Korean and emoji). A test of what's drawn in full far out sets it to 0 (MentionsTests'
  memo at 20%, PreviewTests' preview too small on screen). CanvasTests' Skeletons hold the core: a
  custom skeleton against the render either side of 35%, the default's gray and forms (a disc
  filled, a link stroked, a shape under a pixel the one device pixel its middle is in, whole, even
  with its middle on a pixel's corner, a tiny one its bounds, at 1× and 2×), the shape being edited
  in full and under a skeleton painted over it, the switch, a drawing offset, previews asked for
  only in full, outlines culled (a shape outlined out of view is never asked its outline, one
  straddling the view's edge is outlined), outlines zoomed out (the geometry's, hollow rings that
  unite, `CustomSkeletonOutline`, a translucent ring and stroke no darker where they meet), and
  `drawsSkeletonsDidChange` heard once each way, on a switch after `boardDidChange`, and not for
  editing or a pan; CanvasTests' Skeleton text holds `SkeletonText` (scalars, joiners, a substring
  and a bridged string, fuzzed). SelectionTests' Skeletons hold faces off on a skeleton, a face
  pressed in full not clicked once a pinch has made its shape a skeleton by the release, the hover
  looked at again as the level changes (from the camera and from `skeletonZoom`; not off the
  canvas, mid-press or in the hand tool), and the kept selection bounds
  (`selectionBoundsWorkedOut`, through drags, undo, a link whose end moved and a switch);
  AdornmentsTests' Adornments zoomed out the blank labels (one flat color in their frames, within
  anti-aliasing of the curves they're flattened from, width by columns, Japanese and Korean titles
  within 15% of their width in full and emoji within 30%, hit where drawn, no faces made or kept, a
  button let go and found again and a caption cut shorter as `skeletonZoom` moves under a still
  pointer, Selection's look alone, and the edited shape's labels laid out, drawn pixel for pixel as
  in full and hovered in full at 30% while another's are blank); TitlesTests and LockingTests the
  blank pill and the blank chip that still unlocks; ValidationTests the rings (none grown from an
  outline, none on the shape being edited), and crossing rings in full against an in-test copy of
  the stroke from before the line width and join were set once a frame, pixel for pixel;
  MentionsTests' DrawingTests and FaceTests mention text unbuilt on a skeleton, the
  memo trimmed, and its pills no faces (a click selects, a double-click edits, a locked one's is
  refused and goes nowhere). CompositionTests' `skeletonsShippedTests` hold the shipped pieces
  together: at 30% every shipped shape (a subboard, notes, an arrow, a locked rectangle, a schema
  card and a line) is its skeleton and says nothing, nor do a title's pill and a lock, at 35% it's
  all in full, the note being edited is in full at 30%, and in the app's canvas view a mention's
  pill is no face at 30% and is one again at 35%. `renderBitmap` at a scale other
  than 1 reads pixels with `pixel(_:at:scale:)`: `changedPixels` reads one a point, so it holds
  only at 1×.
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
  send keys with `window.type` and `window.press` (`modifiers:` for ⌘A; `pressCommandPeriod()`
  for ⌘., which the window sends up the responder chain as `cancelOperation:`), and press the
  canvas with `canvas.mouseDown(with: window.mouse(...))`: `sendEvent` mouse-downs don't reach
  views in an unshown window. A click in the panel goes where the window's hit test lands
  (`PanelWindow.hit(_:in:)`, `clickThroughWindow(at:in:)`), since SwiftUI takes the clicks over
  what it disables: a view's own `mouseDown`, called directly, would never meet that. `PanelWindow(editor, inBoardWindow: true)` hosts the panel in a `BoardWindow`,
  for Edit › Undo. A plugin's text box is held with a fixture view (DetailPanelTests'
  `KeyedTextView`, a `DetailTextView` whose value wraps a string, with a `holdsKeys` a test sets,
  logging the commands it gets, its `didChangeText`s and its `show`s): in the panel, a view that
  doesn't hold keys never hears Escape, which the panel's root takes first. `shownWhile` is held
  with a service of the test's own (`Watchers`), and a commit on another shape showing and hiding
  the section, with its tab, while nothing else is built (`countedBuilds`). The caret list is held
  without an owner of the app's (DetailPanelTests' Caret lists): its model and matcher headlessly,
  its window over a plain `DetailTextView` in an unshown window (`ListedText`, whose list opens
  under a range and counts what closes it and what VoiceOver hears), where it's placed but never
  ordered in: read `frame`, call the rows view's mouse methods for a click, and render it with
  `cacheDisplay`; and a subclass's list's keys and closing, which are `DetailTextView`'s
  (`ListingTextView`). A code editor's completions are held in the panel (DetailPanelTests' Code
  completions: `CodeBoxesPlugin`'s code editor completes fruit, `fruitCompletions`, with a basket
  that reopens, a cherry whose count a pick selects, and a word after an x whose range is
  elsewhere, and logs what `onCompleting` hears, `codeCompleting`; `BareCodePlugin`'s has none):
  read the list through the text view's
  `caretListWindow`, and press ⌃Space as `press(" ", code: 49, modifiers: .control)`, ⌥⎋ and F5
  (`"\u{F708}"`, 96, `.function`) likewise; SchemasTests hold the card's (`panelCompletionTests`),
  and CompositionTests the app's menus leaving ⌃Space alone, ⌘↩ with the list open committing,
  and a mouse pick in a board's window (the list made the window's child, as it is shown) joining
  the typing's step.
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
  conflict key names one as `Module.Name`. A plugin list with Titles or Locking needs
  `KeyboardPlugin()`, `SelectionPlugin()` and `AdornmentsPlugin()`, which goes before the plugins
  that place adornments, as the shipped list has it. In debug builds, `editor.adornmentsKept`
  counts the shapes whose labels are kept, so a test holds a deleted shape to being forgotten, and
  `adornmentFacesKept` and `adornmentFacesMade` the shapes whose faces are kept and the faces made
  in all, so one holds zooming out to measuring nothing.
- **The clipboard.** A test that copies gives the clipboard a pasteboard of its own, so it never
  touches the user's: `ClipboardPlugin(pasteboard: NSPasteboard.withUniqueName())`, or
  `ShippedPlugins.makeEditor(pasteboard:model:)` (and `releaseGlobally()` it after). Two editors on one
  pasteboard are two boards copying and pasting between them. ClipboardTests' `moveTests` hold cut
  and paste to a move: the cut's mark, cleared by a copy or any write; a second paste, a copy;
  an id in use, an orphan board or an unreadable entry under a cut id, and a refused deletion, each
  pasting that shape as a copy; a moved copy keeping its `CopiedFrom`; a name left behind naming
  the shape again, and a binding let go.
- **The language model.** Two tests reach the network, and only when asked (`./test.sh` never
  asks): SchemasTests' live smoke test (`SCHEMA_LIVE=1`) and `--ask`'s evaluation (`QUERY_LIVE=1`,
  [`--ask`](#--ask)). Every other shipped list a test builds gets a `ScriptedLanguageModel`
  (`ShippedPlugins.makeEditor(model:)`, whose `model:` has no default so none can be forgotten),
  which keeps each request, answers from its queue, and holds its answers while `holdsAnswers`
  until `release()`. A call lands on the main actor, so a test turns the main run loop until it has
  (TestKit's `spinRunLoop(until:)`, `awaitResult { … }`). LanguageModelsTests stub the network
  itself with a `URLProtocol` (the request's body, `model` and `effort` among it; UnwrapTests,
  `ModelAnswer.unwrapped`).
- **Ports.** PortsTests hold the horizontal without an arrow: `portsHarness` installs Keyboard,
  Selection, Topology, the fixtures, Ports, `channelsPlugin` (boxes have ports on its `Wire` channel, with the
  `sides:` and `role:` a test asks for, and discs on `Pipe`) and a connector over CanvasTesting's
  `Tag` that only records (`connectorPlugin(Connections())`: `begun` lists each `Connection`, its
  session appends each drag to `drags`, and `canConnect` and `draws` make it refuse; its family of
  edges is `Hookup`, and its `edgeTests` hold connections as edges over CanvasTesting's `Link`: a
  channel's type, the family's, none half-bound, an undeclared channel kept as written, one named
  like another plugin's edge type the family's, and none from a connector without `ends`). A 200 × 100
  box at (100, 100), `boxFrame`, has its dots at `topDot`, `rightDot`, `bottomDot` and `leftDot`, at
  zoom 1. A test moves onto a dot before pressing, as a user does (`h.hoverDot` comes from the
  shape's middle): dots draw only while `editor.pointerOverCanvas` is set. ArrowPortsTests draw real
  arrows on a `PortBoard`: boxes A and B where the POC's first two welcome notes are, taking
  `Wire`, and a disc C below B taking `Pipe`; `board.connect(to:speed:release:)` hovers A and drags
  from its right dot (`aRightDot`), `fast` or `slow`, and `board.arrows` are the arrows drawn, with
  their bindings and `ChannelProperty` (and `arrowEdgeTests`, their edges).
- **Topology.** TopologyTests hold it over fixtures only, never Ports, Mentions or a shipped kind:
  `GraphPlugin` declares edge types (`wire`, `hot-wire` under it, `quote`, `cite`) and sources over
  CanvasTesting's kinds (a `Link` bound at both ends is a wire, a `CitingTag`'s target a hot wire, a
  `Tag`'s a `tether` nobody declares, a `Memo`'s own names quotes in their property's slot, and its
  `CitationsProperty` cites, through the property rule), and `graph(file)` opens a harness on it
  with `PocketsPlugin` for boards (`Nest`: pockets two deep, with links across them;
  `hiddenFile()`: a board the app can't show; `signalsPlugin()`, a source that reads only a disc's
  id, over `newerDiscsFile()`'s discs, kept aside). They hold the registry's checks, the tree and
  its filters, emission (order, counts, slots, an edge to itself once, none for a shape kept
  aside), every way a commit comes (an insert, a change, a removal, a move that reads nothing,
  `recordsRead`; `transact(on:)`, a pocket's deletion and its undo, a paste with boards,
  `replaceFile`, `replaceDocument`, Delete Hidden Shapes undone, a switch that reads nothing),
  `end(_:)`, containment, `revision(of:)` and
  `touched`, and `catchUp` from a service made before the index's. Their Snapshots suite holds
  `snapshot()` to the index on every question, over a seeded run of every kind of commit, switch
  and undo on pockets two deep beside a board the app can't show (a snapshot taken a step before
  keeping its old answers), with file order and its keys, orphans and loops, a chain of 2,000
  boards, reads off the main thread (`offMain`), and no record read or observation made taking
  one; CanvasTests' ShowableTests hold `file.canShow` to `editor.canShow`. CompositionTests'
  `topologyShippedTests` hold the shipped graph: note-link, schema-link and plain arrows, and
  mentions across a subboard, by type, `.within` against `.only`.
- **Snapping.** SnappingTests hold `SnapTargets` pure (a rect moved by a delta: where it snaps, and
  its guides), and drags on CanvasTesting's boxes with a move tool of their own, since they can't
  use Selection: `snapHarness` installs the fixtures, Snapping and `movePlugin(moves)`, whose press
  starts a `TranslatingSession` from the press (the select tool's lone box) of what `moves.ids`
  names, else of the shape pressed, in a 1000 × 800 view at 100%, so view points are world units.
  A test that snaps gives the editor a view (`viewportDidResize`): with none, nothing is in view to
  snap to. `editor.snapGuides` is what shows. ⌘ and ⌃ are `h.hold`, and a key let go counts as held
  until `h.wait(150)`. CanvasTests' TranslationAdjusterTests hold the core's hook with a fixture
  adjuster (x on a grid of 10), and CompositionTests' SnappingShippedTests the shipped pieces through
  the select tool: notes, an arrow, a rectangle placed with its tool.
- **The command line.** A test listens on a socket of its own (`temporarySocketPath()`, TestKit),
  never the app's. The app answers on the main actor, so a test that's also the client makes its
  request off the main thread while the main run loop turns (`offMain`), or runs `canvas` as it's
  built (`run(builtExecutable("CanvasCLI"), arguments)`, which turns the loop until it's done).
  CanvasRPCTests hold the wire to its messages, arguments and sockets (and "Answering later", a
  `Holds` listener and a `RawConnection`: answers in order on a connection, one connection never
  waiting on another, a hang-up cancelling what's running, `x-timeout`); CanvasCLITests run `canvas`
  against an app of their own (a listener with a few commands, `FakeApp`) for its output, errors,
  carets and exit statuses; AutomationTests run the commands on a headless editor, spelled as
  `canvas` spells them (`spec.params(from:)`, standard input and all: `run(_:on:input:)`), awaited
  with TestKit's `awaitResult` (and "Commands that answer later": `run:` in one turn, `runAsync:`'s
  output written and freed off the main actor, `ThreadLog`, a `JSON` output passed through, and an
  error's data); and CompositionTests' CommandLineTests run `canvas` against the app's
  `CommandServer` on boards configured as the app configures them (and a `Lingering` board command
  on a server of its own: a closed board answered `board_closed`, and `canvas --timeout` cancelling
  the command).
- **`canvas draw`.** AutomationTests hold `draw` over fixtures, with test plugins in the bridges'
  places (DrawSupport.swift): `namesPlugin` names a tile by its label and a card by its nickname (an
  unnamed one "Card, 100 × 60", worked out from its size), `edgesPlugin` makes
  links, with a tone and heads as added properties, and logs each request (`EdgeLog`), and
  `checksPlugin` warns about a card that says nothing and calls a glossy tile an error. `drawEditor`
  installs them with Automation and the fixtures in an 800 × 600 view; `drawn(script, on:)` is what
  a run that succeeds says, `refused` why one failed, and `rows` and `messages` read a result. The
  bridges' tests do the same over their own plugin and fixtures: TitleNamesTests over Titles
  (cards named, tiles named or worked out, discs worked out), PortEdgesTests over channels of their
  own (`Wire`, `Pipe`) and a link connector that logs its requests, ValidationChecksTests over
  fixture rules. CompositionTests run `draw` through `canvas` as built, on the shipped kinds:
  CommandLineTests' diagram, a second run all `unchanged`, a dry run and error JSON, notes with
  mentions and schema cards as tall as their descriptions; DrawContentsTests' check that a draw bringing
  rows in at several places logs no AppKit warning; DrawBoardsTests' subboards (drawn over, and
  deleted with their boards), a run as one undo step, and schema cards (renamed by their schemas,
  and never asking the `ScriptedLanguageModel` anything); AutomationTests' undo steps, an agent's
  commit, and bindings and names across a file's boards (`DrawFileTests.swift`, with `Pin`, a
  kind a tool places that binds and names); and SkillTests, which runs every example in the canvas skill (`.claude/skills/canvas`), each
  file's fenced blocks in order on a fresh 1440 × 900 board: a block tagged `draw` must succeed
  and push nothing aside, and one tagged `draw-error`, run as a dry run, must fail with the reason
  its first line names (`// reason: <reason>`) and change nothing; and it reads the skill's
  tables of kinds (SKILL.md's and the reference's) and holds each kind's size, attributes and
  channels by side to what `canvas kinds` says. A block tagged `query` or `query-error` runs
  through `canvas query`, its first line a CSS comment saying what it answers (`/* matches:
  "Title", (kind) */`, the shapes in answer order, an untitled one as its kind in brackets, nothing
  after the colon for none; `/* count: N */`) or why it's refused (`/* reason: … */`), and must leave
  the file equal, not edited and with no undo step; a file whose first line is `<!-- board:
  query-story -->` (`reference/query.md`) runs on the story file (`QueryStory.document(windowed:
  false)`, 1440 × 900), and its blocks are held to the design's table of every construct
  (`StoryQuery.table`) and its tables of words and edge types to `canvas query-vocabulary`; and
  SKILL.md's description is held to 1,024 characters. `SKILL_DUMP=1` prints what each example said.
  So a change to either language, their messages, a shipped kind, word or edge type changes the
  skill with it, or CompositionTests fails.
- **Queries.** QueryLanguageTests, QueriesTests, the five bridges' tests, QueryCommandsTests,
  CompositionTests' query suites and BenchmarkTests' Query benchmarks: [Testing
  queries](#testing-queries).
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
  own row alone, and a rename of it to redrawing theirs too. `contents.rowsMade` counts the rows it
  has made, so a test holds going back to a board to making none. The path counts its redraws the
  same way (`boardCrumbs.pathRedrawn`), and how often its crumbs are made (`boardCrumbs.remade`), so
  BoardsTests holds commits on the board shown to redrawing none, and to making none.
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
  (Topology's index of the file's edges and Mentions' catalog, built as the file opens, among it), validation's first read (every
  shape, checked against its kind's schema too) and its reads after a drag event, after a drag
  event of a subboard 100 notes mention (whose mention rule looked it up, and ignores moves) and
  after moving every shape, a hover and a drag frame (titles' pills, locks and mentions'
  pills in view), an empty board's frame on Retina at 100%, 70%, 35% and 10%, the camera still,
  panning and pinching (`Budget.emptyFrame`, 2 ms of the thread's CPU time), a hover on a note's port dot and a drag from it, a hover onto a title's
  pill and onto a mention's, reading the table of contents' rows after a drag event, an insert, a
  delete and a restack, a keystroke in the `@` picker (the `@` that opens it too, on a file of two
  boards, and among thousands of rectangles where only 3 notes can be mentioned), a rename of a
  subboard mentioned 100 times against one mentioned by none (its commit, and validation's read
  after it), the panel's layout of that subboard, its Mentioned In tab showing, after a drag event
  of another note and after a mentioner's rename (`Budget.panelAfterCommit`, 1 ms; the tab's lines,
  `backlinks(of:)`, only reported), what's connected to a shape with 100 edges
  (`topology.neighbors(of:)`, 1 ms), a `canvas draw` of 20 notes each pushed along its row of the
  grid (150 ms, time the window doesn't draw), the minimap's first picture (a frame at a time) and
  a drag frame with it, ten subboards' previews filling in (the longest frame, and how many), the
  first frame and each after zoomed out to fit the board (at 10,000, as far as the 10% zoom goes),
  where shapes are [skeletons](#skeletons) and adornments blank (the first makes the labels of
  every adorned shape in view; a frame each), a pan's frame with every shape selected (⌘A) at 100%
  (the camera a point from the last frame's, so the box around them is worked out again, as in a
  pan), what a board all out of view adds to an empty board's frame, at 100% and 10%, with nothing
  selected and with every shape (1 ms: nothing off screen is drawn, and a shape outlined out of view
  costs a look at its kept extent), and undoing and redoing a drag (with its frame), a tenth of the
  board's move and deletion and every shape's deletion (the steps alone), to their budgets on
  generated boards of 1,000 and 10,000 shapes (`generatedBoard`; three notes in ten mention a
  subboard and a shape that isn't there), and reports ⌘A's pan frame zoomed out, the first frame
  zoomed in to 35% from skeletons (every text in view laid out), and a pinch from 100% to 10% and
  back, a frame at each zoom (in full just above 35%, a frame of the generated board takes more
  than 16 ms).
  Across boards, on files of them
  (`generatedFile(root:children:depth:)`, the shipped
  subboards): opening one whose shapes are spread over nested boards (a tenth on the root, a tenth
  in each of nine subboards, the last a chain ten deep) in the time a board of as many takes;
  entering a subboard of 10,000 shapes cold, with ⌘↓ (the switch and the camera's first fit, a
  frame of notes with pills, the rows and validation's first read, together, in 250 ms; the panel's
  list left out; who mentions whom, Topology's, and Mentions' catalog are the file's, read as it
  opens, so entering reads none of them), and going back up with ⌘↑ (and with the root
  listed whole after it, the selection let go of) and
  down again warm (the same four, in a frame); a hover, a drag and the rows after it on a root of
  1,000 beside a subboard of 10,000, and inside a subboard of 10,000 while the root holds as many,
  each as on one board, with the drag event's input alone (in 1 ms, and at most 3× what it costs on a file of that
  board alone, since drawing would hide a commit's upkeep of the whole file); the minimap's picture of the board entered, a frame at a time; and deleting
  a subboard whose boards hold 10,000 shapes (the commit and every board under it, in a frame), and
  undoing and redoing that (with its frame). It only reports the inspector's list replaced on a
  switch between boards of 10,000 (a `List` in an unshown window, against a 50 ms target), and a
  chain of 1,000 boards written, read, walked (`path(to:)`) and shown. `./test.sh` runs it small, in
  debug, and only reports.
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
  `Blockers` scope; `mentionPlugins` installs the detail panel and the context menu, for the tab
  and Show What Mentions, and `mentionHarness` puts Keyboard, Selection and Topology first). They fuzz the stored
  grammar, hold scopes and their registry checks, names, mention edges (slot, count, order, a
  service made before Topology's catching it up), `MentionState`'s resolutions, observations and
  rows (Topology's `recordsRead` counts the records a commit reads, in debug builds: in these
  fixture lists only Mentions' source reads any), the matcher's tiers, and the
  pill's images; drawing, pixel for pixel against string drawing, and each pill's pixels within
  its `mentionPills` frame (`MentionDrawingCounts`, in debug builds, counts what's built); faces,
  through `EditorHarness`; the text view in an unshown window (`EditedJot`: typing, the picker's
  keys, clicks, the menu, tooltips, copy and paste on `NSPasteboard.withUniqueName()`, undo in a
  plain window, which the view writes back itself, once, and leaving the window with only its own
  steps); the state, the pills and the rows as steps are undone and redone (`editor.undo()`,
  `redo()`: never a record inserted again in undo's place); and the picker's model, headless. AppKit closes an undo group at the end of a turn of the run loop,
  so a test that undoes steps one at a time settles the window (`window.settle()`) between them.
  They hold backlinks too (`backlinkTests`: order and names, quotes cut at either end, the canvas's
  menu item and its one Back step, file-wide (a mentioner on another board listed and quoted after
  the board shown's, the menu item showing its board, a switch putting the new board's first), a
  drag bumping no revision, a mentioner's text changed on another board, and a quoted name changed
  on another board, by `transact(on:)`, a pocket's deletion and its undo, telling the revision's
  observers; the revision's bumps and non-bumps, a drag, a self-mention, undo and redo, with the state's
  tests). Mention text in the panel
  (`panelTests`): `MentionPanel` hosts a `DetailPanelView` in an unshown window with the real
  `TaskScheduler`, and `MentionFieldsPlugin` gives `Jot` a Text field and `Brief` one that commits;
  they hold a pick to one step, the picker's keys against the box's and the panel's, pills clicked,
  deleted and double-clicked, copy and paste, a rename redrawn and the board's undo shown without a
  write, Edit › Undo in a `BoardWindow`, read-only (a pill clicked and followed where the
  window's hit test lands, which SwiftUI would take over a disabled box), ⌘. closing the picker,
  and the picker under its `@` as the panel scrolls. In an unshown window the picker has no parent window, so a test picks with the mouse by
  clicking its rows (CanvasUITests hold a board's child window to not sealing). The Mentioned In
  tab (`mentionedInTests`) is read through `backlinksShown`, since SwiftUI draws its lines: shown
  while mentioned, the lines in order, a click and Back, a line for a mentioner on another board
  (its quote, and a click showing its board), redrawn by a mentioner's change and not by a drag. A line's hover goes untested: SwiftUI's `.onHover` doesn't answer synthesized events.
  StickyNotesTests hold a note's text (its third migration, its row, what it's called) and its
  editor to its render with pills (`noteEditorTests`: each pill's frame in the editor, TextKit 2's
  for its attachment, is the canvas's; at a whole number of pixels to a point, the lines start
  alike and the pills' pixels are within a quarter; at 60%, string drawing draws a pill part way
  into a pixel and TextKit 2 on the nearest, so there only the pixels off the pills are held).
  MentionValidationTests hold the bridge with fixtures of their own (`Card` and `Sheet`
  mentionable, `Blob` not, `Letter` holding `MentionText` and `ScopedMentionText<Only<Card>>`, and
  `Postscript`, an added property of mention text): each warning and its field, missing and
  kept-aside targets, delete and undo, scope, look-alikes (fuzzed: text made from runs has none),
  a locked mentioner, the board shown, and moves: a drag of a target or of its mentioner checks
  no text, and a rename of the target checks its mentioner (`MentionValidationPlugin.textsChecked`,
  debug builds, counts the texts the rule checks).
  CompositionTests' `mentionsShippedTests` hold the shipped pieces together in a `CanvasView`: a
  titled note picked with `@`, renamed (the editor, the row and the canvas), deleted and undone; the
  pill clicked on the canvas and double-clicked in the text; a locked note's pill; copying and
  pasting a pill; a note and the note it mentions cut and pasted as the same shapes, and a titled
  note that mentions an untitled one copied and cut with it; and the text view's undo written back
  to the note. In a
  board's window (`UndoBoard`, whose `BoardWindow` gives Edit › Undo to the text with the
  keyboard), they hold a session begun from a pill, with a pick, Remove Mention, a paste and
  typing, to one step, and a note placed and typed into with a pick to one step with its placing,
  "Add Note"; a pick undone in the text to its query, each undo to one write; Undo with the picker
  open, the text's and the board's, to closing it; a deletion and a rename undone to pills as they
  were; and going to a mention to no step, with Back beside Undo. `backlinksShippedTests` hold Show
  What Mentions among a subboard's own items and the clipboard's, and the Mentioned In tab of a
  note and of a subboard in the shipped panel, in a `BoardWindow` (a line goes to its mentioner,
  and Back returns); ShippedTests a MentionValidation warning in Issues and on its row; and
  CommandLineTests `draw` notes that mention shapes, on the board or not.
- **Board previews.** CanvasTests' PreviewTests drive a `BoardPreviews` of their own over a
  `CanvasFile` (`preview(of:in:)`, `build(in:until:)`: a deadline already past builds one chunk,
  one far off everything; `waiting`, `keptKeys`, and the mask's pixels), and an editor's through
  `renderBitmap`: the first frame asks, and with `editor.boardPreviews.frameBudget` lengthened, the
  next (after `h.wait(0)`, the frame it asked for) draws them. SubboardsTests hold the card's
  pixels the same way.
- **Arrow behavior is pinned to the proof of concept.** CompositionTests replays 28 arrow
  scenarios through `CanvasView` with real events and compares where every arrow ends up, byte for
  byte, with a transcript recorded from the POC. It also compares eight renders pixel for pixel:
  the welcome board, target outlines, binding hints mid-drag, handles and their halos, zoomed out.
  The renders are drawn with [skeletons](#skeletons) off (`skeletonZoom = 0`): the POC drew every
  shape in full at every zoom, so "re-aimed-zoomed-out", at 15%, would differ in the shapes
  themselves, where the app draws them as skeletons on purpose; the goldens stay as recorded.
  The same replay code (`Tests/CompositionTests/Replay.swift`) drives the POC when recording and
  the app when testing. The recordings come only from the POC:
  `scripts/record-poc-fixtures.sh` rebuilds them from commit 804db97, and re-running it should
  change nothing. Never regenerate them from the app to make a change pass. Scenarios are only
  ever appended, and recorded from the POC, with one exception: retiring the arrow tool took the
  scenarios and renders that drew with it, and in their place came re-aims of an arrow's end the
  same ways (the drag a port's connection is drawn with), appended and recorded. The POC's timers
  run on real time, so keep an event well clear of the moment one fires (50 ms or more): a
  scenario that releases 44 ms after the 320 ms timer is due records either way. Where the app
  differs on purpose, the replay says so: the "pan, then re-aim" scenario presses H and holds still
  100 ms before the release (both do nothing in the POC, whose select tool panned), and the welcome
  renders use the POC's note text
  (`pocWelcomeTexts`), since the shipped board's third note describes the hand tool and the
  marquee, and its fourth and fifth linking notes from their ports.
  Where a scenario ends differently on purpose, `intendedDeviations` in TranscriptTests replaces
  the golden's line with the app's, and says why; the fixture stays as recorded. There's one: the
  POC brought a pressed shape to the front and the app doesn't, so "move shape" lists its two notes
  in the other order. The replay runs with Snapping, in its 1000 × 800 view: no scenario moves a
  note within 8 points of lining up with the other, so none snaps, and one appended that did would
  be an intended deviation.

## Coming from data-canvas

| data-canvas | Here |
|---|---|
| `definePlugin({ id, shapes, tools, ... })` | `struct XPlugin: CanvasPlugin { var id; func register(into:) }`. A value; functions can generate plugins. |
| `defineShape({ type, util, tools, toolbarItems, validate })` | `registrar.shape(XDefinition()) { x in x.tool(...); x.validate { ... } }`. The kind comes from the props type and is stamped on everything inside. |
| `ShapeUtil` | `ShapeDefinition`: stateless, typed props, defaults from geometry. |
| Static capabilities on the util (`layoutHostCapability`) | Capability protocols found by `as?` (`Editable`, `HandleProviding`, ...). |
| Slot key + `plugin-slot.ts` + `installArraySlot` | An `ExtensionPoint` type declared by the plugin that owns the concern. No strings, no replay. |
| `validate:` on `defineShape` | Sugar on `ShapeRegistrar` published by the horizontal's own module (`schema.validate { }`); the core has no such field. |
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
| A subboard's `targetPageId`: a tldraw page per subboard, all in one store, the tree worked out from which page holds which subboard | A `BoardOwning` kind, whose board the file keeps under the shape's id (`CanvasFile`, `BoardID(owner:)`), never in its props, so the tree follows from where shapes are ([Boards in a file](#boards-in-a-file)). |
| The page lifecycle's guards: duplicates, cycles, cascade delete, and the orphan sweep with its recovery shapes | Not needed: keyed by its owner, a board can't have two owners or be its own ancestor, deleting a shape takes every board under it in the same commit (one undo step), and a copy has a new id, so a board of its own. Only a file edited by hand breaks the tree, and reading keeps what it can't show, reports it and writes it back (`LoadReport.keptBoards`). |
| `editor.setCurrentPage(targetPageId)`: entering and exiting | `editor.showBoard`, through Selection's opener (`x.opensBoard`: a double-click, Return, ⌘↓, the row, Open), and ⌘↑ (`goToEnclosingBoard`); never an undo step, and each board keeps its camera. |
| `SubboardBreadcrumbs` | `BoardPath` (Boards), over the top middle of the canvas, hidden on the root; a crumb shows its board and selects there the shape the path came through. |
| A crumb's hover menu (`CrumbButton`'s popover, a level as `TocLevel` renders it, compact, one shape highlighted) | A crumb's menu: the crumb's own board's rows as the table of contents lists them (`ContentsOutline` over `ContentsState.outline(of:)`), the way you came highlighted, as data-canvas's first menus listed a crumb's children (its later ones show the level above, VS Code's siblings); data-canvas's 150 ms hover intent each way; a row picked goes into a board-opening kind's shape (`goInto`), else to the shape (`goTo`). |
| `generateBoardPreview` on the card | `context.drawBoardPreview(ofBoardOwnedBy:in:)`: every shape a silhouette in one gray, as the minimap draws, built a chunk a frame. |
| `install*Lifecycle(editor)` side effects | `registrar.willDelete` inside transactions; `EditorService` for per-editor state. |
| `module.json` + ESLint DAG + barrel `index.ts` | `Package.swift` with layers + `build.sh audit` + the compiler; `public` is the barrel. |
| `plugins.config.ts` | `ShippedPlugins.plugins(pasteboard:model:)` in Composition. |
| The query DSL's `#kebab-title` | A title in double quotes, `"Checkout"`, the whole title folded, case and all, as `draw` matches it; `#` takes a shape's id alone (`#Checkout` is `not_an_id`, hinted `"Checkout"` where a shape has that title). |
| `.Class` (`node.`, `edge.`) | Refused: `.Task` is `not_built` (shapes typed by schema cards may be one day); a kind is its id, `sticky-note`. |
| `:source-of`, `:target-of` | `:edge-to`, `:edge-from`, the words data-canvas moved to (#87), kept with `:downstream-of` and `:upstream-of`, over Topology's typed edges; the old words are refused with the word to write. |
| `:connected-to`, one edge until 8a4d798d, any number after it (with no message) | Picked on purpose, from the first rounds of `--ask`'s evaluation: `:connected-to(S)` is one edge either way, as "connected to" reads (Haiku 4.5 wrote it for "what's connected to Checkout?" even beside the prompt's example of `:neighbor-of`, this language's word until then, now refused with `:connected-to`), and any number of them is `:component-of(S)`, the anchor's connected component. |
| `:has(S)`: an edge to a shape S matches | CSS's `:has`, containment: S inside it at any depth, `:has(> S)` on its board. The one word whose meaning moved; an edge either way is `:connected-to(S)`. |
| Scope globs, `:on-page` | Containment in the selector: `"Payments" *`, `:top-level`, `:current-board`; `:on-page` is refused with `"Board" *`. |
| `:selected`, dropped | Back: the engine runs in the live app, over what's selected as the query starts (SelectionQueries). |
| An unknown pseudo-class accepted and ignored | Refused, with the one like it or the rewrite (`KnownInventions`); every name is resolved against the registry, and every title and id against the file, before anything is answered. |
| `nl-translate.ts`'s prompt, and the task's move from Haiku 4.5 to Sonnet 4.5 | `QueryPrompt.system`, ported where it still applies (the output contract, the direction procedure, "do not invent new ones"), taught on the story file and held to the language by tests; `--ask` runs on either model through `AskStyle`, and the live evaluation's bar picks the cheaper that clears it: Sonnet 5.5, in round 2. |

## Not built yet

Each of these adds to the design without changing what plugins are written against.

- **More of change sets:** each commit already says what it added, changed and removed
  (`ChangeSet`, which services get with `documentDidChange`), and undo keeps the records before and
  after (`DocumentDelta`); what's left of who made it is more than whether an agent did
  (`ChangeSet.byAgent`): which agent, or which person. Sync builds on them.
- **More of the command line**: reading positions back (a query's rows say what a shape is, what
  it's called and which board it's on, never where it sits there, so an agent that places shapes
  against ones it didn't draw can't see where they are); who each change is from (an agent's name
  on its commits, and its cursor on the canvas); commands contributed by the plugins that own a
  concern (a title, a lock), where `draw` does everything today; opening a board that isn't open;
  putting `canvas` on the PATH from the app (as editors install theirs); and other clients of the
  same socket (an MCP server, say, from the same command descriptions).
- **Addressing a board of a file from the command line**: a command works on the board a file's
  window shows (`canvas boards` says which, and a board command's result); naming another
  (`--board 2/<owner id>`, or a path of titles), so `draw` could reach a subboard's board without
  the person opening it, is still to come (a query lists a file's boards already, by their owners:
  `subboard`, each row with its `board` and `inside`).
- **More of `canvas draw`**: labels on edges (arrows carry no text, so an edge can't either);
  containers and groups, which hold what's in them, grow with it and move as one (a zone is a
  plain shape today, and what's in it is placed once); edges routed around shapes; extending a
  list across runs other than by restating every member; chains (`edge "A" -> "B" -> "C"`);
  naming a shape the user left untitled; mentions written by title in a note's text, which only
  ids write today; a schema card titled in its statement, as other kinds are, where its schema's
  `"title"` names it; and `THIRD_PARTY_NOTICES.md` in the app, which carries reladraw's attribution
  only in the repository today.
- **An arrow end bound to a shape that isn't there** (deleted outside a transaction, or kept aside)
  is drawn at the origin; a binding should keep a point to fall back on.
- **More of undo**: showing a change that's out of view as it's undone (the camera never moves
  today); a limit to how many steps a file keeps (there's none); NSDocument's rollback of an
  autosave it can't finish, given up with the undo manager; text's undo falling through to the
  board's once the text has nothing left to undo (it's forgotten when the text loses the keyboard);
  agents' changes as steps of their own, with who made them; and a change that lands on its own
  during a press (a model's answer the schema card's sync writes) kept out of the press's step,
  which it joins today on the board shown (one that lands on another board is a step of its own,
  `transact(on:)`).
- **More document hooks** (before/after create and change), and **document-scoped services** for
  several windows on one board.
- **More of schema cards**: keeping the last sync in the card's metadata, so any card saved out of
  step (a failed sync, a call cut off by closing) opens knowing it, not only one whose schema has
  no fields; a patch in place of the whole schema, so a big schema can be edited from its
  description (and a long one answered sooner); streaming, for answers longer than a request that
  doesn't stream should wait for; and schemas that type or check other shapes.
- **An editing view hearing about outside changes** to its shape, whatever writes them:
  `EditContext.shape` reads it as it is, and a schema card's editor shows its description as the
  sync writes it, watching the sync's status for it; a note's hears nothing (undo, a draw and a file
  put in place end editing first).
- **Canvas features**: resize and rotate handles on the selection box; ⌥-drag to clone; the scribble brush; a long press starting a drag;
  the "move" cursor while moving shapes; and hierarchical tool states once the select tool has more
  than a handful of sessions.
- **More of snapping**: resize handles snapping as they're dragged, once there are any (tldraw's
  `snapResizeShapes`), and arrows' ends and other handles (tldraw's handle snapping); a grid; a
  setting that turns snapping off, or makes it tldraw's (only while ⌘ is held); kinds saying what
  they snap by (tldraw's `getBoundsSnapGeometry`: points of their own, or none), which only having
  a frame decides today; guides for shapes the size of what moves (Freeform's); a frame's neighbors
  when the nearest is past the next 64 frames along the axis, which a board zoomed far out over
  thousands of shapes can miss; and shapes just out of view.
- **More panning**: right-button drags (the right button is the context menu's today); Space held
  mid-drag panning while the drag goes on (tldraw's; the hand held today pans from the next press);
  the hand tool's double-, triple- and quadruple-click zoom; and a slide, and edge scrolling, timed by the display rather than nominal
  16 ms frames.
- **More horizontals** from data-canvas: describe, ranked or semantic search (a query's
  `:contains` is a filter), commands. Each is an extension point in its own plugin.
- **More of titles**: a double-click on a pill renaming it (an adornment's own double-click: a
  double-click there is its shape's today, which edits a note); a Rename item in the context menu;
  and titles on kinds without a frame, such as arrows (tldraw's labels, along the arrow) and lines.
- **More of adornments**: more places (the other corners and edges, below a shape, and along a
  shape without a frame, as an arrow's label); an adornment's own double-click and menu items;
  labels read from other shapes (with an `affected:`, as the table of contents' marks have);
  adornments that draw themselves (data-canvas's 22-point sparkline, which needs a taller row);
  adornments painted with their shape, so a shape in front covers a back shape's, and a press
  there is the front shape's (a per-shape drawing hook in the core); a tooltip on each (the lock's
  among them); telling agents what a shape shows; and labels not made at all zoomed far out (drawn
  blank, none is measured, but the first frame there still asks every adorned shape in view for
  its labels).
- **More of skeletons**: a level that holds while the zoom hovers about it (hysteresis, or tldraw's
  debounce, which keeps a big board's level from when the camera started moving until it stops),
  since today a pinch across 35% flips every shape each time it crosses; zooming in by degrees,
  skeletons turning into their shapes a frame's budget at a time, as previews fill in, where the
  frame that crosses the level draws every shape in view in full at once; and a level per kind, or by a shape's size on screen, where one zoom decides for the canvas.
- **More of going back**: going forward again (⌘]), and a step keeping what the table of contents
  listed, so Show All survives a trip back.
- **More of the keyboard**: a window listing every shortcut; menu items that take their key
  equivalents from Keyboard, so the View menu's zoom keys and Edit › Select All's ⌘A are declared
  once; and keys the user remaps.
- **More of the table of contents**: nested shapes (a shape's container as the default
  `nestedUnder`), with each row's disclosure remembered (every nested row starts collapsed today);
  dragging rows to restack their shapes; per-kind zoom targets (data-canvas's `getZoomConfig`);
  a double-click on a row opening its shape in the app's panel, which shows the picked shape's
  panel in the list's place before the second click; arrow rows that name the shapes they join; and rows all of one height, which AppKit
  never measures from inside a measurement, so it would stop logging its reentrancy warning
  ([What's listed](#whats-listed-and-selecting)): a list of our own, since a SwiftUI `List`'s rows
  size themselves. The same would make a switch of board cheap with the panel showing the list:
  today every row is replaced (its id is the board's), some 120 ms going into or out of a board of
  1,000 shapes and a second at 10,000 (40 s or more the first time 10,000 show), where
  `./build.sh bench` reports a 50 ms target it doesn't hold, and the budgets for entering a board
  leave the list out.
- **More of validation**: listing just the shapes with issues in the table of contents (a filter
  beside Show All), and going to the next one from anywhere (Xcode's ⌘'), for a board too big to
  look down for dots; an issue in the Issues tab going to the row it's about, which the panel would
  mark (below); rules that depend on the clock (a deadline passed), which the engine, caching by
  revision, can't keep up to date today; and checking boards that haven't been shown: the engine
  checks the board shown, so the issues on a board inside a shape (schema warnings included)
  appear only once you enter it, and nothing on the shape that owns it sums them up.
- **More of the clipboard**: pasting what other apps put on the pasteboard (text as a note, an
  image) and giving them a text or image version of copied shapes; ⌘V pasting at the pointer
  (tldraw's preference, and ⌥; the context menu's Paste lands at its click already); and Duplicate
  (⌘D) and ⌥-dragging a copy, on the same copying.
- **More of the context menu**: key equivalents and symbols on items; and Duplicate, in
  Clipboard's group, once a plugin owns it.
- **More of locking**: Unlock All (tldraw has it); the menu's other items for a locked shape dimmed, rather than shaking it once chosen;
  a line in the detail panel saying why it's disabled; and a tooltip on the chip (an adornment's,
  above).
- **More of ports**, most of which data-canvas has: a channel's cardinality (at most one
  connection at an end, and a dot that stops taking more); wildcard channels (a port on every
  channel); directional reversal (a drag from a port that only takes connections, drawn the other
  way round); ports on part of a shape (a row, a schema card's field); an arrow's start pinned to its
  dot's side, and its end to the side of its shape facing it (data-canvas's `anchorToPort`; a
  precise start at a side's midpoint means nothing without it, since tldraw's clipping starts an
  arrow where it crosses its shape's edge toward the other end, whichever side that is); a
  channel's title, and a legend of the channels; a line in an arrow's detail panel naming its
  channel; and rules that read connections (which Topology's index can answer: a schema's links,
  say). Rectangles and subboards have no ports, so a person can't connect them (`canvas draw` still
  can, on no channel).
- **More of boards**: moving shapes into a subboard, or up out of one (Move to Subboard), keeping
  their ids as a cut and its paste do, in one step, with a check that no shape goes into its own
  board; arrows across boards (an end bound
  to a shape on another board: bindings stay on their board, and a copy lets go of the rest); the
  selection remembered per board, so going back into a board selects what was selected there
  (nothing is selected on arrival, and only Back returns to it); a crumb's menu from the keyboard
  (it shows only for the pointer), and the boards "…" folds each with a menu of its own;
  renaming a board from inside it (the path's last crumb, or the table of contents' header), which
  writes its owner's title on the board above, with `transact(on:)`; a mark on a shape's row (and
  its card) for issues on the boards inside it, and validation and Find across a file's boards (the
  engine checks the board shown: More of validation, above); two windows on different boards of one
  file (one editor holds the file and shows one board, so a window is a file's: a store of boards,
  each window's editor showing one, would keep every host's `let editor`); Open in a menu for
  several shapes opening each, or only showing for one (a per-shape `when` can't see the
  selection's size, so it opens the first); a line in the Board tab saying what the board holds; a
  preview in another color, or sharper than 256 pixels when a card is shown large; and a board
  addressed from outside the app (the command line's, above).
- **More of topology**: containers that aren't boards (frames, groups) as sources of containment,
  a point of their own; `canvas draw` matching an edge it restates by its type as well as its ends;
  showing a shape's connections of every type in the app (a Connections section of its panel,
  beside Mentions' Mentioned In); and edges on the boards the app can't show, which carry none
  today.
- **More of queries**: where shapes sit (`:near`, `:left-of`, `:within`, overlaps, and attributes
  that hold a place, which are `not_built`; inside is a board's), and positions in rows; shapes typed
  by schema cards (`.Task`); attributes inside attributes (`[a.b]`) and `=` on an object; ranked or
  semantic search, a horizontal of its own; `--select` and `--reveal` on a query, to show the person
  what it found; a query box in the app, and saved queries; the warm cache that's the next step
  should queries asked again and again miss their budgets (a title index and attributes kept by a
  worker, marked stale from each change set only while warm, and dropped after idle minutes);
  text formats that read the typed value (a note's parsed mentions) rather than the stored string,
  so Mentions' doesn't parse each note's text again (half of what a mentioning note's row costs).
- **More of properties**: a board's shapes checked against their schemas as it opens, in its report
  (`canvas draw` warns about what it draws, and `canvas kinds --schema` hands the
  schemas out); a projection of
  a schema for LLM tool calling, whose strict modes reject `prefixItems` and `oneOf` (a rect, a
  string enum); panel controls made from a schema, a title's field counting down to its
  `maxLength`; bounds a kind sets on an added property (Titles' 80 characters are every kind's);
  sections and menu items that turn on a property whose default is nil (they show only once it's
  set today); and discarding a kept value.
- **More of checking shapes against their schemas**: `unevaluatedProperties`, `dependentSchemas`
  and references to other documents, which no schema here writes; and checking only the parts of a
  shape its schema bounds, for the first read of a large board (10,000 shapes take about 30 ms).
- **More of mentions**: a shipped text in the panel that holds mentions (`MentionTextArea` is
  there for one); saying in the `@` picker which board a shape on
  another board is on; validation across boards (MentionValidation checks a mention of a shape on
  another board no more than a missing one); a text restricted to some kinds among the
  shipped ones; a move that isn't a cut and paste (Move to Subboard, below), keeping ids as a cut's
  paste does, so mentions stay live; the command line reading and listing what can be mentioned,
  and helpers for writing mentions; more kinds mentionable (through bridges); and making a shape
  from the picker.
- **More of the detail panel**: editing several selected shapes at once (it shows "N Shapes"
  today); every-shape sections over the record (there are every-box ones over the frame, and those
  over an added property; so `mentionableEveryShape` brings no Mentioned In tab), and every-box
  overrides such as an aspect lock;
  remembering the chosen tab and collapsed sections across launches (`DetailTabID.name` is stable
  for that); and marking the row a validation issue is about (`ValidationIssue.field`).
