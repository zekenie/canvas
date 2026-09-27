# The plugin system

Everything on the canvas comes from a plugin: sticky notes, ellipses, arrows, task cards,
validation, checklists, the detail panel and the table of contents beside the canvas, selecting
itself, copying and pasting, what each key does, even the examples.
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
- [Selection](#selection)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [The detail panel](#the-detail-panel)
- [Context menus](#context-menus)
- [The table of contents](#the-table-of-contents)
- [The clipboard](#the-clipboard)
- [Capabilities](#capabilities)
- [The editor, the document, and drawing](#the-editor-the-document-and-drawing)
- [Boards on disk](#boards-on-disk)
- [The registry](#the-registry)
- [Testing plugins](#testing-plugins)
- [Coming from data-canvas](#coming-from-data-canvas)
- [Not built yet](#not-built-yet)

## Four nouns

| | What it is | Example |
|---|---|---|
| **Kind** | A plain value type holding a shape's data. It names itself once, with `static let kind`. | `struct StickyNote: BoxShapeProps { frame, text, checklist }` |
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
    public var frame: CGRect
    public init(frame: CGRect = .zero) { self.frame = frame }
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

`Rectangle` is the kind: its data, named once. `RectangleDefinition` says how it looks, and a kind
with a frame needs to say nothing else. `RectanglesPlugin` registers both, with a tool that puts a
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
  `RectanglesPlugin()` to `ShippedPlugins.all`. The list's order is the toolbar's, and the order
  overlays draw in.
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
| Add a concern any kind can opt into | An `ExtensionPoint`, sugar on `ShapeRegistrar`, and whatever reads the point | [Titles](#a-horizontal-plugin), [Validation](../Sources/Validation/Validation.swift) |
| Give that concern a tab on the kinds that opt in | A `DetailTab` at order 50, contributed from the same sugar | [Checklists](#a-horizontals-feature-tab-checklists) |
| Give that concern menu items on the kinds that opt in | A `MenuGroup` at order 50, and `contextMenu` from the same sugar | [Checklists](#a-feature-that-comes-with-menu-items-checklists) |
| Opt another plugin's kind into a concern | A bridge, which imports both | [EllipseTitles](#a-horizontal-plugin), [ValidationDetails](#footer-lines-from-a-bridge-validationdetails) |
| Keep state per editor: an engine, a cache, a timer | `registrar.service`, an `EditorService`; redo what's kept per shape for the shapes each commit's `ChangeSet` names | [Validation](../Sources/Validation/Validation.swift)'s `ValidationEngine` |
| Draw above every shape, or beside the shapes in view | `registrar.overlay`, a `CanvasOverlay`; `editor.paintOrder(in: context.visibleRect)` | [Titles](#a-horizontal-plugin), [Checklists](../Sources/Checklists/ChecklistOverlay.swift) |
| Let go of shapes as they're deleted | `registrar.willDelete` | [Arrows](../Sources/Arrows/ArrowDefinition.swift) |
| Create a kind with a double-click on empty canvas | `x.createOnDoubleClick(place)` | [StickyNotes](../Sources/StickyNotes/StickyNotes.swift) |
| Keep a kind from being selected | `x.unselectable()`, or `x.selectable { ... }` | [Selection](#selection) |
| Keep a kind from being copied | `x.uncopyable()`, or `x.copyable { ... }` | [The clipboard](#the-clipboard) |
| Make copies of a kind name the copies of the shapes it names (a connector) | `ShapeReferencing` | [Arrows](../Sources/Arrows/ArrowDefinition.swift) |
| Keep something about any shape beside its props (where it came from) | A `ShapeMetaKey`, and `record.meta[Key.self]` | [Metadata](#metadata) |
| Show or dim a right-click item by more than its shape | `.shown { record, editor in ... }`, `.enabled { ... }` | [The clipboard](#the-clipboard)'s Paste |
| Show a shape's state at the foot of the panel | `registrar.detailStatusForEveryShape` | [ValidationDetails](#footer-lines-from-a-bridge-validationdetails) |
| Change a shipped kind's props | A migration in its `static let migrations`, and a fixture for the new version | [Boards on disk](#boards-on-disk) |

The rule of thumb: behavior intrinsic to a kind is a [capability](#capabilities), a protocol its
definition adopts; behavior any plugin can add to any kind is an extension point.

## Horizontal and vertical

A **vertical** plugin is a feature: a shape kind and the tool that places it, or a tool on its own.
Sticky notes, ellipses, arrows, task cards, rectangles, polylines and the eraser are verticals.

A **horizontal** plugin is a concern that cuts across kinds. It declares an extension point, and any
kind can take part by contributing to it. Validity is the canonical example: *a shape can be valid
or invalid* is horizontal; *an empty sticky note is invalid* is one vertical opting in. Titles are
another. The horizontal owns the contract, the engine, and whatever it draws. Shapes never know
they're invalid; the validation plugin outlines them.

A horizontal can also be a feature that individual shapes opt into, and that shows up in the
[detail panel](#the-detail-panel) as a tab of its own, and in the [context menu](#context-menus).
Checklists is the example: one line, `note.checklist(\.checklist)`, gives sticky notes a checklist
stored in their own props, a Checklist tab in the panel, its bulk actions in the context menu, and a
done/total chip on the canvas. Checklists owns the item type and everything
done with it; the kind only stores the items. One horizontal may build on another: Checklists
imports DetailPanel and ContextMenus.

Selecting is a horizontal too, one that every kind is in unless it opts out
(`backdrop.unselectable()`). [Selection](#selection) owns what's selected and the way back
through it, the Select tool, and Delete, Return, ⌘A and Back; the detail panel builds on it to
show the selected shape. So are the keys: [Keyboard](#keyboard-shortcuts) holds every shortcut,
and a plugin whose tool or command has a key registers it there.

Opting in goes in one of two directions:

- **The vertical imports the horizontal** and contributes from inside its own `register`.
  StickyNotes does this for Validation: `note.validate { ... }`.
- **A bridge imports both**, and neither knows the other. `EllipseTitles` gives ellipses a title,
  though Ellipses has never heard of titles and Titles has never heard of ellipses. A bridge may
  join two horizontals: `ValidationDetails` shows each shape's validation issues in the detail
  panel's footer, though Validation has never heard of the panel, nor the panel of validity.

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
.target(name: "StickyNotes", dependencies: ["Canvas", "Checklists", "Selection", "Validation"]), // layer: vertical
.target(name: "EllipseTitles", dependencies: ["Canvas", "Ellipses", "Titles"], path: "Examples/EllipseTitles"), // layer: bridge
```

| Layer | May depend on | Modules |
|---|---|---|
| foundation | foundation | Geometry, Canvas (the core) |
| ui | foundation | CanvasUI (the AppKit view, the SwiftUI toolbar, and `CanvasFocus`) |
| horizontal | foundation, horizontal | Keyboard, Selection, Validation, Titles, DetailPanel, ContextMenus, TableOfContents, Checklists, Clipboard |
| vertical | foundation, horizontal | Arrows, StickyNotes, Ellipses, TaskCards, Rectangles, Polylines, Eraser, Reordering |
| bridge | foundation, horizontal, vertical | EllipseTitles, ValidationDetails |
| composition | foundation, horizontal, vertical, bridge | Composition (the shipped plugin list) |
| app | foundation, ui, composition | InfiniteCanvas |
| testsupport, test | (see Package.swift) | TestKit, CanvasTesting, `*Tests` |

What `./build.sh audit` enforces:

- **No cycles.** The graph is sorted topologically; a cycle is printed as a path.
- **Layers.** A horizontal can't import a vertical, a vertical can't import another vertical, the
  app reaches plugins only through Composition, and nothing but the app and tests sees CanvasUI.
- **Imports match the manifest, both ways.** The compiler lists each module's imports. An import
  that isn't a declared dependency fails, and so does a declared dependency that's never imported.
  `@_exported`, `@_implementationOnly` and `@testable` are banned, since each hides an edge, and
  so are imports inside `#if`.
- **No other module's ids as literals.** A module that writes another module's kind, plugin or
  tool id as a string literal (`kind == "sticky-note"`) without depending on it fails. An id is a
  module's when it declares it as a static `ShapeKind`, `ToolID` or `PluginID`, or as its plugin's
  `id`. Lookups at run time (a tool by its shortcut or label) aren't audited.
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

- **The kind is its props.** `ShapeProps` values are `Codable`, `Equatable` and `Sendable`.
  `BoxShapeProps` adds a `frame`, and with it most behavior for free. The document stores each
  shape as an `AnyShapeRecord` (id, kind, props). Definitions get it typed, as `ShapeRecord<Rectangle>`.
- **The definition is stateless.** For a box kind, only `render` is required. The rest has defaults:

  | Requirement | Default |
  |---|---|
  | `geometry(of:in:)` | the frame (box kinds); every other kind must say ([a shape without a frame](#a-shape-without-a-frame)) |
  | `hitTest(_:on:in:)` | inside the geometry's closed outline |
  | `hitMargin` | none: how far past its geometry's bounds `hitTest` can still say yes |
  | `indicatorPath(of:in:)` | the geometry's outline (the target hint, and hover and selection outlines) |

  `geometry` is the one source of truth. Override it and hit testing, the outline, the marquee and
  arrows all follow. Override `hitTest` or `indicatorPath` only when you can do better; Ellipses
  does both (an exact hit test, a smooth outline). A `hitTest` that reaches past the outline (a
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
        shape.props.isEmpty ? [.warning("This note is empty.")] : []    // no text and no checklist
    }
    note.checklist(\.checklist)              // opts into Checklists: a panel tab and a chip
}
```

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

When the eraser deletes a shape an arrow is bound to, the arrow lets go of it by itself: the
arrows plugin registered a `willDelete` handler. The eraser never heard of arrows.

The details:

- **`Tool`**: `pointerDown` (may start a session), `pointerMoved` (hover, with no session
  running), `pointerExited`, `modifiersChanged`, `cursor(in:)`, `cancel` (Escape; return true if
  you handled it). All but `pointerDown` have defaults.
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
    public var points: [CGPoint]
    public init(points: [CGPoint] = []) { self.points = points }
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
  with the pointer's offset from the press. Escape puts the shape back without your help.

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
of its own (`PaintOrderAnchored`), and a translation that keeps its bindings.

## A horizontal plugin

A horizontal declares an extension point, gives other plugins a pleasant way to contribute, and
consumes what they contribute. [`Examples/Titles`](../Examples/Titles/Titles.swift) is the smallest
one:

```swift
extension PluginID {
    public static let titles: PluginID = "titles"
}

/// ① The extension point: declared and read by this plugin, filled by others.
public enum ShapeTitles: KeyedExtensionPoint {
    public typealias Contribution = @MainActor (AnyShapeRecord) -> String?
    public static var owner: PluginID { .titles }
    public static func uniqueKeys(of _: Contribution, for target: ShapeTarget) -> [AnyHashable] { [target] }
}

/// ② Sugar, so opting in is one line: `note.title { $0.props.text }`.
extension ShapeRegistrar {
    public mutating func title(_ make: @escaping @MainActor (ShapeRecord<Definition.Props>) -> String?) {
        contribute({ $0.typed(as: Definition.Props.self).flatMap(make) }, to: ShapeTitles.self)
    }
}

extension PluginRegistrar {     // for a kind another plugin registers (bridges use this)
    public mutating func title<P: ShapeProps>(_: P.Type, _ make: @escaping @MainActor (ShapeRecord<P>) -> String?) {
        contribute({ $0.typed(as: P.self).flatMap(make) }, to: ShapeTitles.self, for: .kind(P.kind))
    }
}

/// ③ The consumer: a lookup, and an overlay that shows the hovered shape's title.
extension Registry {
    public func title(of shape: AnyShapeRecord) -> String? {
        contributions(to: ShapeTitles.self, for: shape.kind).first?(shape) ?? nil
    }
}

/// The hovered shape's title, just below it (`hovered` is Selection's: on the canvas, or its row).
struct TitleOverlay: CanvasOverlay {
    var space: OverlaySpace { .view }       // drawn in view points

    func draw(in context: OverlayContext) {
        let editor = context.editor
        guard let id = editor.hovered, let shape = editor.document[id], let title = editor.registry.title(of: shape),
              let bounds = context.shapes.geometry(of: id)?.bounds else { return }
        let corner = editor.camera.toView(CGPoint(x: bounds.minX, y: bounds.maxY))
        NSAttributedString(string: title, attributes: TitleStyle.attributes)
            .draw(at: CGPoint(x: corner.x, y: corner.y + TitleStyle.gap))
    }
}

public struct TitlesPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .titles }
    public func register(into registrar: inout PluginRegistrar) {
        registrar.overlay(TitleOverlay())
    }
}
```

And the bridge that opts ellipses in, [`Examples/EllipseTitles`](../Examples/EllipseTitles/EllipseTitles.swift):

```swift
registrar.title(Ellipse.self) { ellipse in "Ellipse, \(Int(ellipse.frame.width)) × \(Int(ellipse.frame.height))" }
```

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
- **Engines are services.** A horizontal with state (a cache, an index) registers an
  `EditorService`, made per editor, with `registrar.service { ValidationEngine(editor: $0) }`, and
  anyone finds it with `editor.service(ValidationEngine.self)`. Validation's engine recomputes when
  `editor.revision` changes and is cached otherwise.
- **Horizontals draw their own decoration** through `registrar.overlay`, above every shape. World
  overlays draw with the camera transform; view overlays draw in view points.
- **Contracts should be pure.** Validation rules read the document only through
  `ValidationContext`, so dependency tracking can replace full recomputation later without
  changing any rule. Design your contexts the same way.

[Validation](../Sources/Validation/Validation.swift) is the full-size version of the same pattern:
per-kind rules, rules for another plugin's kind, rules for every kind, an engine, and an overlay.

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
  as it would in tldraw, which strokes a hover like the selection.
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
- `hoveredHandle`, `brush` (the marquee), `selectionBounds`, `isSelectable(_:)`, and the commands'
  `selectAll()`, `deleteSelection()` and `editSelection()`.

**Opting out.** Every kind is selectable unless it says otherwise, for all its shapes or for some:

```swift
registrar.shape(BackdropDefinition()) { backdrop in backdrop.unselectable() }
registrar.shape(LockableDefinition()) { lockable in lockable.selectable { !$0.props.isLocked } }
```

The select tool sees through such a shape: a press lands on whatever is beneath it (or on the
canvas, where a drag is a marquee), and the marquee and ⌘A pass it by, so it's never selected,
outlined on hover, or shown in the detail panel. It still draws, and everything else treats it as
usual: arrows bind to it, the eraser erases it, code moves and deletes it. A place tool still puts
one down and drags it, with nothing selected; a double-click on it goes to what's beneath, so an
unselectable `Editable` kind is edited only as it's placed. A shape that stops being selectable
leaves the selection with the change that did it. The rule is `ShapeSelectability`: at most one per
kind, plus one for every kind, which a kind's own overrides.

**Opting in** to the rest:

- `note.createOnDoubleClick(place)` fills `DoubleClickPlacement`: what a double-click on empty
  canvas places, at most one kind. StickyNotes does, so it can't be installed without Selection.
- `HandleProviding` is Selection's capability: handles on the only selected shape. The select tool
  finds, draws and hit-tests them; the definition says what a press and a drag do.
- `BrushHitTesting` is Selection's capability for a kind that decides for itself whether the
  marquee touches it. The default is `ShapeGeometry.isHit(byBrush:)`, from its geometry.
- Arrows (to select the arrow it draws, and for its handles), DetailPanel (to follow the selection)
  and Titles (for the hovered shape) import Selection too.

**The select tool** follows tldraw's states. Handles win, then the selectable shape under the
pointer, then empty space inside a multi-selection's box, then the canvas.

- A press on a shape selects just it, and leaves it where it is in the paint order (as tldraw
  does; the POC brought it to the front); ⇧ adds it. With ⌘, or on a
  shape already selected, the press keeps the selection, so a drag past the 4-point threshold
  moves it all; released without a drag, it selects the shape under the release (⇧ or ⌘ toggles it
  instead). A lone box pressed without ⇧ or ⌘ follows the pointer from the press, with no
  threshold. A double-click edits an `Editable` shape, selected alone.
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
```

| Sugar | For |
|---|---|
| `x.tool(label:systemImage:shortcut:placing:)` | A place tool, and the key that switches to it. |
| `registrar.tool(descriptor, shortcut:) { ... }` | Any tool, and its key. |
| `registrar.shortcut(chord, forTool:)` | A key for a tool registered elsewhere: Keyboard gives the core's Hand its H this way. |
| `registrar.command(command, shortcuts: [...]) { ... }` | A command (what a menu item runs) and the keys that run it, so the menu and the keys do one thing. |
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

- **A chord** (`KeyChord`) is a key and the modifiers held with it. A character literal is a key
  alone (`"v"`), and a letter's case doesn't count; `KeyChord("a", .command)` is ⌘A, and the keys
  that type no character have names (`.escape`, `.return`, `.enter`, `.delete`, `.deleteForward`,
  `.tab`, `.space`, the arrows). It describes itself as menus do: `⇧⌘G`, `⌫`.
- **One shortcut per chord.** Two plugins wanting one key are `RegistryError.conflict`
  (`keyboard and clash both claim shortcut H in KeyboardShortcuts`), and a key for a tool no plugin
  registers is `invalid`. A plugin with a key imports Keyboard, so a plugin list with Selection or
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
  panel gives the keyboard back to the canvas. The menu bar's other key equivalents (⌘S, ⌘Z, the
  View menu's zoom) belong to their items and work wherever the keyboard is.
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
│ ‹ ☑  Write the spec                                 │ header: back, symbol, title, subtitle
│      Done · 2 of 5 · Due Sep 30                     │
│ ⟦ Task ⟧   Checklist   Style   Arrange              │ tab strip, hidden with one tab
├─────────────────────────────────────────────────────┤
│      Title  [ Write the spec              ]         │ a tab's first section: untitled,
│     Status  [ ● Done               ⌄ ]              │   never collapses
│   Priority  [ Low | Med | High ]                    │ rows: label column, then control
├─────────────────────────────────────────────────────┤
│ › Notes                                             │ a titled section collapses,
├─────────────────────────────────────────────────────┤
│ ⌄ Schedule                                          │   and may have one header control
│        Due  ☑ [ 9/30/2026 ]⇅                        │
│   Estimate  [   4 h ]⇅                              │
│  Remaining  0 h                                     │ a read-only row
│                        (scrolls)                    │
├─────────────────────────────────────────────────────┤
│ ⚠ Done, with 3 unchecked items.                     │ footer: status lines, on every tab,
└─────────────────────────────────────────────────────┘   hidden when empty
```

The panel owns all of the chrome, and plugins fill it in:

| The panel decides | Plugins provide |
|---|---|
| The header's layout, and its back button (Selection's `goBack`, shown while there's a step back) | The header's title, subtitle and symbol (a value, not a view) |
| The tab strip, the tab order, and the tab remembered per kind | Which tab each section goes in |
| Section chrome: the header, chevron, header-control slot, insets, dividers, collapsing, and remembered collapse | Section titles, ids and order, and at most one header control per section |
| Scrolling, the footer, and the empty states | The rows in a section, and the footer's lines |
| Fonts, control size, the label column and checkbox toggles, all through the environment | |
| Focus: what gives the keyboard back to the canvas | |

With nothing selected the panel shows its overview, a view the host may give it (the app's is
[the table of contents](#the-table-of-contents)), else "No Selection". With several, it shows "N
Shapes" over the kinds selected, then the overview (details are per shape: editing several at once
isn't built). A shape nothing contributes
to (an arrow, today) gets its header, then "No Options". Without `DetailPanelPlugin` installed, the panel says
"No Details".

Sections are stock SwiftUI plus a few primitives, and get the look by following these conventions:

- **Rows.** A labeled control is `LabeledContent("Due") { control }`; the panel lines every label
  up in one 72 pt column and hides the control's own label (its placeholder stays). A read-only
  value is `LabeledContent("Remaining", value: ...)`. A toggle stands alone, drawn as a checkbox
  with its label after it; in a row, it's a bare box.
- **Primitives.** A number is a `DetailNumberField`, and a pair of them (Width and Height) goes in
  `DetailFields`. Multiline text is a `DetailTextArea`, a list a `DetailList` (empty, it says No
  Items), a color `DetailSwatches` (named presets, the chosen one marked, then the color well; it
  spans the row, so it goes in a section of its own, not in a `LabeledContent`). `DetailNumberText` formats and parses numbers with units
  ("240 pt"), in the user's locale ("2,5 h" in German), as the number field does.
- **Sections.** A tab's first section may be untitled; use it for the main properties. Every
  titled section collapses. Titles are one or two nouns in Title Case.
- **Header control.** At most one small control, acting on the whole section (Checklists' menu). A
  switch for one row goes in that row, beside what it governs (the task's Due checkbox).
- **No styling of your own.** No fonts, sizes, padding or backgrounds.
- **Writes** go only through the section's `ShapeBinding`. Sections never see the editor.

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

Use the shared `StyleTab` and `ArrangeTab` rather than near-duplicates. Two tab types with one title
would show as two identical tabs, so they're a registry error (`invalid`, below).

### Contributing: two points and their sugar

| Point | Kind | Holds |
|---|---|---|
| `ShapeDetails` | keyed | A header and sections, one contribution per `details` call. Each section claims (target, tab, id), and a header claims its target, so two plugins adding a Color section to a kind's Style tab, or two headers for one kind, are a `conflict`. A kind's own section and an every-box one may share an id; both show. |
| `DetailStatuses` | list | Footer lines, as `@MainActor (AnyShapeRecord, DetailContext) -> [DetailStatus]`. |

Plugins write the sugar, not the points:

| Sugar | For |
|---|---|
| `x.details(header:) { sections }` | This kind's header and sections, inside `registrar.shape { x in ... }`. |
| `registrar.details(P.self, header:) { sections }` | Another plugin's kind, typed as its own (bridges). |
| `registrar.detailsForEveryBox { sections }` | Every shape with a frame, editing the frame. Arrows have none, so they don't get these. |
| `registrar.detailStatusForEveryShape { shape, context in ... }` | Footer lines for every shape. Return `[]` when there's nothing to say. |

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
| Sections in a tab | The kind's own (from its vertical, a horizontal it opts into, or a bridge), in plugin order and builder order; then every-box sections, in plugin order. |
| Tabs | By `order`, then first appearance over the same sequence. A tab with no shown section is dropped. |
| Footer lines | The kind's, then every kind's, each in plugin order. |
| Header | The kind's own; else the label and symbol of the tool that places the kind; else the kind's name. A header without a symbol takes the tool's. |

`DetailPanelState` (`editor.detailPanel`) gathers each kind's contributions once, since the
registry is frozen, and resolves the selected shape's layout (running `when` and the headers) as
it's shown. It also remembers, per editor and in memory, the tab last chosen for each kind and the
collapsed sections. A collapsed every-box section collapses for every kind; a kind's own, for
that kind only.

### A horizontal's feature tab: Checklists

The pattern the panel is built for: a horizontal exposes a way for individual shapes to opt into a
feature, and the feature shows up as a tab in the panel. Opting in is one line on the kind, and the
tab comes with it, on exactly the kinds that opt in.

[Checklists](../Sources/Checklists/Checklists.swift) gives any kind a checklist, stored in the
kind's props. Checklists owns the item type, its helpers (`doneCount`, `progress`, `setAllDone`,
`removeDone`), the bulk actions (`ChecklistBulkAction`), the tab, and the chip it draws on the
canvas. Its sugar contributes to its own point
and to the panel's, from the same `ShapeRegistrar`, fully typed:

```swift
/// The extension point: which kinds have a checklist. At most one per kind.
public enum ShapeChecklists: KeyedExtensionPoint {
    public typealias Contribution = ChecklistContribution    // how to read the items, and the badge flag
    public static var owner: PluginID { .checklists }
    public static func uniqueKeys(of _: ChecklistContribution, for target: ShapeTarget) -> [AnyHashable] { [target] }
}

extension ShapeRegistrar {
    /// Gives this kind a checklist, stored at `items` in its props: a Checklist tab in the detail
    /// panel, and (unless `badge` is false, for kinds that draw their own) a small done/total chip
    /// on the canvas. `note.checklist(\.checklist)`.
    public mutating func checklist(_ items: WritableKeyPath<Definition.Props, [ChecklistItem]>, badge: Bool = true) {
        contribute(ChecklistContribution(items: { $0.typed(as: Definition.Props.self)?.props[keyPath: items] }, showsBadge: badge),
                   to: ShapeChecklists.self)
        details {
            DetailSection("Items", in: ChecklistTab.self) { $shape in
                ChecklistRows(items: $shape[dynamicMember: items])
            } accessory: { $shape in
                ChecklistMenu(shape: $shape, items: items)
            }
            DetailSection("Progress", in: ChecklistTab.self, when: { !$0[keyPath: items].isEmpty }) { shape in
                ChecklistProgress(items: shape.wrappedValue[keyPath: items])
            }
        }
    }
}
```

- **Opting in.** Sticky notes write `note.checklist(\.checklist)`, task cards
  `task.checklist(\.checklist, badge: false)`, since a card draws its own list.
- **The graph.** StickyNotes imports Checklists and never DetailPanel or ContextMenus, yet gets a
  panel tab and menu items. The requirement shows up at startup instead: a list with StickyNotes but
  without `ChecklistsPlugin`, `DetailPanelPlugin` or `ContextMenusPlugin` is `ownerNotInstalled`,
  naming the missing one.
- **The key path is the contract.** `$shape[dynamicMember: items]` turns the key path into a
  binding that writes only that field. The Items header's menu is a `ForEach` over
  `ChecklistBulkAction` (Check All, Uncheck All, Remove Checked), each disabled unless
  `isEnabled(for:)` and applied in one `update`:
  `$shape.update { action.apply(to: &$0[keyPath: items]) }`. The rules live on the enum, so tests
  check them without opening the menu.

Another feature in this pattern has the same parts: its data type, a keyed point holding an erased
accessor per kind, a tab type at order 50 (and a menu group, if it has actions), sugar that takes a
`WritableKeyPath` into the kind's props and contributes to its points, and whatever consumes the
point (a lookup on `Registry`, an overlay).

### Footer lines from a bridge: ValidationDetails

The footer is for a shape's state, not its settings.
[ValidationDetails](../Sources/ValidationDetails/ValidationDetails.swift) fills it with each
shape's validation issues. It's a bridge between two horizontals, and its imports are the only
edge between them:

```swift
import Canvas
import DetailPanel
import Validation

public struct ValidationDetailsPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "validation-details" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.detailStatusForEveryShape { shape, context in
            (context.service(ValidationEngine.self)?.result(for: shape.id)?.issues ?? [])
                .sorted { $0.severity > $1.severity }
                .map { DetailStatus($0.message, tone: DetailStatus.Tone($0.severity)) }
        }
    }
}
```

Issues come worst first (ties keep the rules' order), each in its severity's tone. A status
contributor reads services through `DetailContext`, read-only. Footer lines are re-read on every
document change, so read a cached service, as this one reads validation's engine. Without
Validation installed there's no engine, and no lines. So an empty sticky note says "This note is
empty." in the footer, and StickyNotes didn't change.

### The full showcase: TaskCards

[TaskCards](../Sources/TaskCards) is a vertical whose panel is its only editor: task cards aren't
`Editable`. Press T to place one. Every field in the panel changes how the card draws.

```swift
registrar.shape(TaskCardDefinition()) { task in
    let place = task.placement(size: TaskStyle.size) { TaskCard(title: "New Task") }
    task.tool(label: "Task", systemImage: "checklist", shortcut: "t", placing: place)
    task.validate { shape, _ in shape.props.issues }
    task.taskPanel()                                  // below
    task.checklist(\.checklist, badge: false)         // the Checklist tab, without the chip
}
```

`taskPanel()` (in [TaskCardPanel.swift](../Sources/TaskCards/TaskCardPanel.swift)) is one
`details` call, here abbreviated:

```swift
details(header: { DetailHeader($0.props.isUntitled ? "Untitled Task" : $0.props.title, subtitle: $0.props.summary) }) {
    DetailSection(in: TaskTab.self) { $task in
        LabeledContent("Title") { TextField("Title", text: $task.title) }
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
        LabeledContent("Remaining", value: DetailNumberText.format(task.remaining, unit: "h"))
    }
    DetailSection("Color", in: StyleTab.self) { $task in ... }
    DetailSection("On the Card", in: StyleTab.self) { $task in ... }
}
```

Four plugins fill one card's panel:

| Part | Holds | From |
|---|---|---|
| Header | the title (or "Untitled Task"), and a summary: "Done · 2 of 5 · Due Sep 30" | TaskCards |
| Task (0) | an untitled section (Title, Status, Priority), Notes, Schedule | TaskCards |
| Checklist (50) | Items, and Progress once there are items | Checklists, through `task.checklist` |
| Style (100) | Color, On the Card | TaskCards |
| Arrange (200) | Size, Position | DetailPanel, for every box |
| Footer | the task's issues, worst first ("A task needs a title.") | ValidationDetails |

### Reading and writing: `ShapeBinding`

A section's content closure gets a `ShapeBinding`. Take it as a `$` parameter, as with
`ForEach($items) { $item in }`:

- **`task.title` reads the snapshot** the panel drew with. Nothing in a section reads
  `editor.document`, so a section isn't rebuilt when other shapes change.
- **`$task.title` is a `Binding`.** Each set writes that one key path into the *live* shape, in its
  own `editor.transact`. A move made after the snapshot survives a rename, two writes in one action
  both land, and setting the value the shape already has commits nothing.
- **Writes go to the shape the binding was made for**, never to whatever is selected by the time
  they happen. A write to a shape that's gone does nothing.
- **Read-modify-write goes in `update`**: `$task.update { $0.checklist.removeDone() }` applies the
  change to the live value, in one transaction.
- **Bind the narrowest key path.** A collection's binding (`$task.checklist`, and the row bindings
  `ForEach` derives from it) writes the whole collection, rebuilt from the snapshot. Use `update`
  for list operations.
- **Every-box sections get a `ShapeBinding<CGRect>`**, the frame, whatever the kind. Typed props
  come only from contributing for the kind: from its own plugin, a horizontal it opts into, or a
  bridge.
- **Other forms.** A plain parameter works too (`shape.wrappedValue` is the snapshot, as in
  Checklists' Progress), and a larger section can be a View declaring
  `@ShapeBinding var shape: Props`, passed `$shape` (Checklists' `ChecklistMenu`).

Tests and tools reach the same bindings with `editor.shapeBinding(id, as: TaskCard.self)` and
`editor.frameBinding(id)`.

Two compiler rules come with this:

- **Keep the sugar's closure types unannotated.** Annotated `@MainActor`, Swift 6.3 compiles a
  `$`-parameter body as nonisolated, and every view initializer in it fails.
- **Never name `Transaction` in a file that imports SwiftUI.** SwiftUI has its own `Transaction`,
  and its `Canvas` view shadows the core module, so `Canvas.Transaction` doesn't resolve either.
  Let closure inference type `$0`.

When each control commits:

| Control | Commits |
|---|---|
| Text fields, `DetailTextArea` | On every keystroke, so the canvas follows as you type |
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
- **Inside the panel**, Tab moves between text fields (a `DetailTextArea` takes Tab as text), and
  Return commits a number and keeps the field. Checkboxes don't take the keyboard (the macOS default
  without Full Keyboard Access); a pop-up, segmented control or stepper that has it keeps
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
selected shape and its footer lines, and rebuilds the shape's panel only if either changed;
dragging another shape costs one comparison. A section is rebuilt only when its own shape changes.
Only the current tab is built, a collapsed section's content isn't, and each kind's contributions
are gathered once.
For your part: sections read only their binding, `when` and footer lines stay cheap, and anything
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
│ Cut                     │  every shape's (Clipboard): Paste dimmed with nothing to paste
│ Copy                    │
│ Paste                   │
├─────────────────────────┤
│ Arrange               ▸ │  every shape's (Reordering): Bring to Front, Bring Forward,
└─────────────────────────┘    Send Backward, Send to Back
```

A shape nothing offers anything has no menu: the right-click does nothing. As shipped, every shape
has the clipboard's items, so that's only empty canvas; an arrow's menu is those alone, since
Arrange leaves it out.

### Contributing

| Sugar | For |
|---|---|
| `x.contextMenu { items }` | This kind's items, inside `registrar.shape { x in ... }`. A horizontal's opt-in sugar calls it too. |
| `registrar.contextMenu(P.self) { items }` | Another plugin's kind, typed as its own (bridges). |
| `registrar.contextMenuForEveryShape(where:) { items }` | Every shape, over `AnyShapeRecord`. `where:` picks kinds by their definition, and so by capability (`{ !($0 is any PaintOrderAnchored) }`); `when:` picks shapes (`{ $0.box != nil }` for those with a frame). |

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
- **`when` leaves an item out; `isEnabled` dims it.** A context menu shows only what applies, so
  reach for `when`. `isChecked` checks it (✓ for every shape, – for some). An item that depends on
  more than its shape (a horizontal's rules, a service, the pasteboard) adds `.shown { value,
  editor in ... }` or `.enabled { value, editor in ... }`, which hold together with `when` and
  `isEnabled` and see the selection the menu is for (Clipboard's Paste is
  `.enabled { _, editor in editor.canPaste }`).
- **`Submenu(title) { items }`** shows when any of its items does.
- **Groups are types**, like tabs: a separator falls between groups, which sort by `order`, then by
  first appearance, in the tabs' bands. An item names its group with `in:`; the default is
  `ShapeMenuGroup`.

  | Order | Groups |
  |---|---|
  | 0 (the default) | A kind's own items (`ShapeMenuGroup`) |
  | 50 | A horizontal's feature, on the kinds that opt in (`ChecklistMenuGroup`) |
  | 100 and up | Shared by every kind (`ClipboardMenuGroup`, 100; `ReorderMenuGroup`, 200) |

- **Keyed.** Each item claims its target, group and `id` (the title by default), and an item in a
  submenu its path, so two plugins adding one item to a kind are a `conflict`
  ("sticky-note Check All"), and so are two for every shape. A kind's own item replaces an
  every-shape one with the same group and id.

### A feature that comes with menu items: Checklists

The pattern of the detail panel's feature tabs, again. Checklists' opt-in sugar contributes to its
own point, the panel's, and this one, so `note.checklist(\.checklist)` brings the Checklist tab and
the bulk actions, each shown only where it has something to do:

```swift
public enum ChecklistMenuGroup {}
extension ChecklistMenuGroup: MenuGroup {
    public static var order: Int { 50 }
}

// In ShapeRegistrar.checklist(_:badge:), after `details { ... }`:
contextMenu {
    for action in ChecklistBulkAction.allCases {
        MenuItem(action.title, in: ChecklistMenuGroup.self, when: { action.isEnabled(for: $0[keyPath: items]) }) {
            action.apply(to: &$0[keyPath: items])
        }
    }
}
```

A future horizontal does the same inside its own sugar: its point, its tab, its menu items, one line
on the kind. The edge comes with it: Checklists imports ContextMenus, so a list with Checklists needs
`ContextMenusPlugin` too. A feature whose menu items should be optional puts them in a bridge
instead.

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
| Where nothing applies | Nothing: no menu, and the selection and any editing stay. That's the rest of the canvas, a kind nothing contributes to, or items all left out by `when`. |
| During a press | Nothing. |

The select tool's hit rule finds the shape, so unselectable shapes are seen through. Opening a menu
ends editing. A right-click opens the menu in any tool; a Control-click only in the select tool,
since other tools may read ⌃ as a modifier.

With several shapes, an item shows when every one of them shows it: the same group and id, whichever
plugin contributed it for each kind, so a note and a task selected together share Check All. It's
enabled when it is for any of them, and runs on those: each kind's own `edit`, all in one
transaction, then each contribution's `perform` once, with its shapes. It's checked (✓) when every
shape checks it and mixed (–) when some do; a kind whose item has no `isChecked` counts as
unchecked. A submenu holds what its items resolve to. In a group, a kind's own items come first, then every shape's, each in plugin and
builder order.

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
│   ◐ Write the spec             1/3  │ a task: its status as a symbol, in the pill's color
│   ○ Untitled Task                   │   a blank title shows the placeholder, dimmed
│   ◯ Ellipse                         │ a kind with no row: its tool's label and symbol
│   ↗ Arrow                           │ an arrow that starts on nothing, at the top
└─────────────────────────────────────┘
```

### A kind's row

StickyNotes' row, in full ([NoteRow.swift](../Sources/StickyNotes/NoteRow.swift)):

```swift
note.contentsRow { note in
    ContentsLabel(note.props.text, placeholder: "Empty Note", color: .yellow, badge: note.props.checklist.tally)
}
```

- **The row is a view the kind builds**, usually a `ContentsLabel`: a title on one line (each run of
  whitespace folds into a space), a placeholder shown dimmed when the title is blank, an SF Symbol
  (the placing tool's, unless the row gives one) with an optional color, and a badge of a few
  characters at the trailing end ("2/5", "Sep 30"). The list owns everything around it: row
  height, indentation, disclosure triangles, selection, the header. Any view works, but
  `ContentsLabel` is what keeps rows from different plugins alike; use it unless a row really needs
  something else.
- **A row reads only its shape.** A shape's row is made again only when that shape changes, so
  dragging another shape costs one comparison.
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

| data-canvas's `TocCardProvider` | Here |
|---|---|
| `component` | The view `contentsRow` builds, usually a `ContentsLabel` |
| `filter` | `when:` |
| `getParentShapeId` | `nestedUnder:` |
| `getZoomConfig` | The shape's geometry bounds, with 100 points of margin, for every kind |
| `onClick`, `getGroupChildren` | Not built yet |
| The "other" row (type and id) | The placing tool's label and symbol |

### What's listed, and selecting

- **Rows are in document order**, back to front, like data-canvas's z-ordered outline. Selecting a
  shape doesn't restack it, so rows move only when shapes are restacked (Bring to Front).
- **Selecting filters the list**, like data-canvas's multi-select summary: select several shapes
  on the canvas and only they are listed, under their header ("2 Shapes") and "Selection"; select
  nothing and the whole board is, under "Board"; select one and the panel shows its details. Show
  All lists the board again without deselecting.
- **Selecting rows** (a click, ⌘- and ⇧-clicks, the arrow keys) selects their shapes and brings
  them into view: centered, zoomed to fit with 100 points of margin but no closer than 120%, over
  200 ms (data-canvas's click-to-zoom, and tldraw's zoomToBounds). A click on one row selects one
  shape, so its details replace the list, as in data-canvas. ⌘- and ⇧-clicks leave several
  selected, and the list keeps listing what it listed, so rows can be added and taken out without
  the rest going away. That holds until the selection next changes some other way, which
  `editor.selectionRevision` tells apart from the same shapes selected again.
- **Hovering links the two.** There's one hovered shape, Selection's `editor.hovered`, and both
  sides set it and show it. The pointer on a row hovers its shape, as the pointer on the shape
  would, and the canvas outlines it faintly. The pointer on a shape on the canvas tints its row:
  a faint accent where the selection's highlight goes, in its shape. A selected shape shows neither,
  only its selection. data-canvas marks a row when its shape is hovered on the canvas (a faint ring);
  its rows don't hover the canvas.
- **Going back.** A row's click is a step in Selection's history like any other change of the
  selection, so the back button in the shape's header (or Go › Back, ⌘[) brings the list back,
  with the view as it was before the zoom, as data-canvas's back button does.
- **The keyboard.** A click gives the list the keyboard, as a source list does: the arrow keys move
  through the rows, Delete runs the `.delete` command (deleting the selected shapes, as Delete on
  the canvas does), and Escape gives the keyboard back to the canvas (`onExit`). So does hiding the panel while the list has the keyboard.
- **Headless**, `ContentsState` (`editor.tableOfContents`) is all of it: `entries` (the rows, a tree),
  `scope`, `select(_:)`, `showAll()`, and the rows' hover: `hover(_:)` and `endHover(_:)` as the
  pointer moves onto a row and off it, and `isHovered(_:)` for whether a row shows as hovered. Tests
  read a row's text, symbol and badge through `entry.label`.

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

Bringing shapes into view takes two generic things from the core: `editor.viewportSize`, which
`CanvasView` reports as it's resized, and `editor.animateCamera(to:duration:)`, eased like
tldraw's camera moves and stopped by any other camera change, as the hand tool's slide is.
`Camera(fitting:in:inset:maxZoom:)` (Geometry) does the fit.

## The clipboard

Cut, copy and paste are a horizontal ([`Sources/Clipboard`](../Sources/Clipboard)) built on three
others: Selection (what's copied, and what's selected after a paste), Keyboard (⌘X, ⌘C and ⌘V) and
ContextMenus (Cut, Copy and Paste on every shape). The core has never heard of a clipboard. It
lends three generic things: commands (`.cut`, `.copy` and `.paste`, which Edit › Cut, Copy and
Paste send), shape [metadata](#metadata), and the `ShapeReferencing` [capability](#capabilities).

| | Does |
|---|---|
| ⌘C, Edit › Copy, Copy | Puts copies of the selection's copyable shapes on the pasteboard, back to front. The board doesn't change. |
| ⌘X, Edit › Cut, Cut | Copies, then deletes what it copied, in one transaction. What can't be copied stays. |
| ⌘V, Edit › Paste, Paste | Puts the copies on top of the board, with new ids, and selects them. |

- **Copies get new ids, and remember their originals.** Each pasted shape's metadata names the
  shape it was copied from: `record.copiedFrom`, which is `meta[CopiedFrom.self]?.shape`, and its
  board keeps it. That's the shape the copy was made from: a copy, if a copy was copied; in
  whichever board it was copied from, this one or another; and maybe gone since (a cut shape always
  is). Pasting twice makes two copies of the same shapes. The rest of a shape's metadata comes
  with it.
- **Where a paste lands** is tldraw's: where the originals were, if any of them would be in view
  there; otherwise centered in the view, the shapes keeping their places among themselves. A paste
  in place lies exactly over its originals, as in tldraw and Figma. Moving them is
  `transaction.translate(ids, by:)`, which moves every kind as dragging would: boxes by their frame,
  others by their `CustomTranslation`.
- **Shapes that name shapes.** A kind whose props name other shapes (an arrow's bound ends) adopts
  the core's `ShapeReferencing`. Copying asks it to let go of the shapes left out of the copy, and
  pasting asks it to name the copies of those copied with it. So two notes and the arrow between
  them paste as two notes and an arrow between the copies, and an arrow copied alone pastes free,
  ending where it was drawn, as it would if its notes were deleted. tldraw's copy does the same.
- **The pasteboard** holds a small board: `BoardCodec`'s JSON, each kind at its version, under the
  app's own type. So one window can paste what another copied, a paste into a newer app migrates as
  opening a board does, and a kind the board doesn't install is left out of a paste. Anything else
  on the pasteboard (text, an image from another app) is left alone for now: ⌘V does nothing, and
  its key goes on. `ClipboardPlugin(pasteboard:)` takes the pasteboard, the system's by default.
- **Where the keys work.** ⌘X, ⌘C and ⌘V are Keyboard's while the canvas has the keyboard.
  Elsewhere the menu has them: the board's window controller answers Edit › Cut, Copy and Paste
  wherever the keyboard is, the table of contents' list included, except in text (a note being
  edited, a panel's field), which takes them first. Cut and Paste don't run mid-gesture; Copy does.
- **In the context menu**, every shape has Cut, Copy and Paste, in `ClipboardMenuGroup` (order 100,
  before Arrange). Like the rest of the menu they're for the selection; Paste is dimmed with nothing
  to paste. They depend on more than the shape (the copyability rules, the pasteboard), so they use
  ContextMenus' editor-aware modifiers: `.enabled { record, editor in ... }`.

**Opting out.** Every kind is copyable unless it says otherwise, for all its shapes or for some, as
with selecting:

```swift
registrar.shape(TicketDefinition()) { ticket in ticket.uncopyable() }
registrar.shape(StampDefinition()) { stamp in stamp.copyable { !$0.props.isSealed } }
```

A selection's uncopyable shapes are left out of a copy, and stay when it's cut. With only such
shapes selected, ⌘C and ⌘X pass the key on, and Cut and Copy are dimmed in the menu. Everything
else treats them as usual: they're selected, moved, deleted and erased. The rule is
`ShapeCopyability`: at most one per kind, plus one for every kind, which a kind's own overrides.

### Metadata

A shape's metadata (`AnyShapeRecord.meta`) is the core's place for what a plugin keeps about a
shape that isn't the kind's own data, such as where it was copied from. A member is typed by a key
the plugin that owns it declares, as an extension point is:

```swift
public enum CopiedFrom {}
extension CopiedFrom: ShapeMetaKey {
    public typealias Value = CopySource        // { shape: ShapeID }
    public static var owner: PluginID { .clipboard }
    public static var name: String { "copiedFrom" }
}
```

Read it with `record.meta[CopiedFrom.self]`, and change it in a transaction:
`tx.update(id) { $0.meta[Key.self] = value }`. A board keeps it beside the props, by
`owner.name` (`"meta" : { "clipboard.copiedFrom" : { "shape" : "…" } }`), members no installed
plugin knows included, and a copy (`record.copy(as:)`) takes it along. Unlike props, members
aren't versioned: add only optional fields to a value, since one that no longer decodes reads as
nil.

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
| `PaintOrderAnchored` | Painted just above another shape, whatever its place in the document. The anchor follows from the shape's own props and the document's order, since the paint order is kept until one of those changes. | Arrows (above the shapes they join) |
| `ShapeReferencing` | Props that name other shapes. `remappingReferences(of:_:in:)` passes each through a map: named as the shape it gives, or, for nil, let go of as a deletion would. Whatever copies shapes calls it through `record.remappingReferences(_:in:)`; a kind that names no shape needs nothing. | Arrows (a copy stays bound to the copies of its shapes, and lets go of the rest where it's drawn) |

The rule of thumb: behavior intrinsic to a kind is a capability; behavior anyone can add, to any
kind, from any plugin, is an extension point. What a kind shows in the detail panel is an extension
point, not a capability: the kind's own plugin, a horizontal it opts into, and a bridge can all add
to it.

## The editor, the document, and drawing

- **The document is a value.** `CanvasDocument` holds every shape, back to front, in the order of
  their stacking keys: each record carries its own (`stackingKey`, a fractional index as in
  tldraw), so moving a shape in the stack changes that shape alone. The only way to change it is
  `editor.transact { tx in ... }`: `insert` (on top), `update` (typed with `as:`; it can't change a
  shape's id or key), `bringToFront`, `sendToBack`, `move(_:above:)`, `move(_:below:)`, `delete`,
  and `translate(_:by:)`, which moves shapes as dragging them would. A record carries its props and
  its [metadata](#metadata), and `record.copy(as:)` is the same shape under another id.
  A transaction commits once, if anything changed, and bumps `editor.revision`. What it did goes
  with it, record by record: its `ChangeSet` names the shapes it added, changed and removed, and
  says whether the stack changed. Transactions don't nest. A frame that isn't finite never gets in: such an insert or update is dropped, since a board
  must always save. Undo (not built yet) will group commits: everything from a press to its
  release, and everything while a shape is being edited, will be one step.
- **`willDelete`** handlers run inside the deleting transaction, before anything is removed, so a
  plugin can let go of shapes that are about to disappear (arrows bake their curve there). They may
  delete more; each shape's handlers run once.
- **The hint** (`hintedShapeID`, a target outlined whatever the tool) always names a shape that
  exists, and so does `editingShapeID`, the shape being edited. After every transaction that
  changed the document, services hear `documentDidChange` with its change set: they drop what's
  gone (the selection does), and redo what they keep per shape for just those shapes (validation
  does). What's selected is [Selection's](#selection).
- **What the editor keeps.** Each shape's geometry and extent (its geometry's bounds, with its
  box), and the paint order, from one frame to the next, so a frame costs what's in view and what
  changed rather than what's on the board. A shape's geometry is kept until the shape changes or a
  shape its definition looked up through its `ShapeContext` does. The paint order is kept until
  the stack changes or an anchored shape's anchor does, which is why an anchor follows from the
  shape's own props and the document's order. `editor.shape(at:)` asks a shape's `hitTest` only
  about points within its extent grown by its `hitMargin`, and `editor.paintOrder(in:)` is the
  paint order of just the shapes that may show in a world rect: what drawing goes through, and
  overlays too, with `context.visibleRect`. Code that runs per frame doesn't go through every
  shape; `./build.sh bench` holds a hover and a drag at 10,000 shapes to a frame (16 ms).
- **Drawing**, back to front: background and grid; shapes in paint order (culled by extent: those
  more than 40 world units out of view don't draw, and a shape with no outline always does); every
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
  API. Only the app and tests can import CanvasUI, and no plugin can see the host API, so no
  plugin can reach around the editor.

## Boards on disk

A board is a file (`.canvasboard`; `.board` is Freeform's), one per board, opened and autosaved in place by `BoardDocument`
(CanvasUI, an `NSDocument`). `BoardCodec` (Canvas) reads and writes it: JSON, sorted and
pretty-printed, so a board diffs cleanly.

```json
{
  "format" : 1,
  "schema" : { "arrow" : 0, "sticky-note" : 1 },
  "shapes" : [
    { "id" : "…", "index" : "a0", "kind" : "sticky-note", "props" : { "frame" : [[80, 80], [200, 200]], "text" : "…" } },
    { "id" : "…", "index" : "a1", "kind" : "sticky-note", "props" : { … }, "meta" : { "clipboard.copiedFrom" : { "shape" : "…" } } }
  ]
}
```

`format` versions the envelope, and `schema` each kind's props. A shape with
[metadata](#metadata) has it in `meta`, and one without has none, so boards from before it read
as they did (an app from before it reads such a board, and drops `meta` when it saves). The camera, the selection and
whether the details show aren't in it: they're remembered per file on this Mac, so panning never
marks a board edited.

**A kind versions its own props.** Its migrations sit beside `static let kind`, and their count
is the version boards record. A migration rewrites one shape's props as JSON (`JSONObject`), since
old props may no longer decode:

```swift
public struct StickyNote: BoxShapeProps {
    public static let kind: ShapeKind = "sticky-note"
    /// Append only. The count is the version boards record.
    public static let migrations = [
        PropsMigration("notes get a color") { props in props["color"] = "yellow" },
    ]
    ...
}
```

- Any change to how a kind's props encode needs a migration: a member renamed, removed or
  retyped, a changed unit or meaning, a new member that isn't optional. (Swift's synthesized
  `Codable` ignores defaults when a member is missing; a new optional member needs none.)
- Migrations are append only, pure (only that shape's props: no registry, no other shapes, no
  clock, no randomness) and up only.
- A kind's string never changes once shipped.
- A value several kinds store (Checklists' `ChecklistItem`) is versioned by each kind that stores
  it: its owner publishes the step, and each kind appends it.
- Each shipped kind has a fixture per version, `Tests/CompositionTests/Fixtures/kinds/<kind>.v<N>.json`,
  one shape's props as boards of that version wrote them. `expectKindFixtures` (CanvasTesting)
  checks that every fixture migrates and reads, and that today's writes back byte for byte, so a
  props change without a migration fails. Add a fixture for each new version; never edit one.
  The registry's report shows each kind's version once it has one (`shape sticky-note v1`).

**Opening never drops a shape.** What the app can't use is kept aside (`AnyShapeRecord.isOpaque`),
in its place in the stack, and saved back as it was, with its own version (`v`): a kind no plugin
installs, a newer version of a kind, or props that don't read (or don't migrate, or have a frame
that isn't finite). Nothing draws, hits, selects or edits a kept-aside shape; a horizontal that goes
through every shape skips `isOpaque` records, as Validation does. Opening also repairs ids that
repeat or are missing, and stacking keys that don't rise. `LoadedBoard.report` says what was kept
aside and repaired; the window shows it, and repairs mark the board edited, so saving keeps them.
Only a file that isn't a board, or comes from a newer app, refuses to open (`BoardReadError`).

## The registry

`Registry(plugins:)` runs every plugin's `register(into:)` once, after the core's own plugin (the
hand tool). It then checks everything and throws on:

| Error | When |
|---|---|
| `duplicatePlugin` | The same plugin id twice. |
| `ownerNotInstalled` | A contribution to a point whose owner isn't in the list. |
| `unknownKind` | A contribution for a kind no plugin registers. |
| `conflict` | Two claims to the same key: a kind, a tool id, a service type, a command, the default tool, the secondary click, key strokes, or a key in any `KeyedExtensionPoint` (a keyboard shortcut's chord, one kind's double-click claim). |
| `invalid` | A point's own `check` refused the list (the default tool must be a registered one). |

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

Once built, it's frozen and handed to the editor. The app's list is `ShippedPlugins.all` in
[Composition](../Sources/Composition/ShippedPlugins.swift), and a test checks it registers.
`registry.report` prints who contributes what: the runtime half of the graph, pinned by a test.

```
core                tool hand
keyboard            service KeyboardState · key strokes · shortcut H → tool hand · shortcut ⎋ → Cancel · shortcut ⌘. → Cancel
selection           service SelectionState · tool select · shortcut V → tool select · default tool select · outlines · overlay HandlesOverlay · command delete · shortcut ⌫ → command delete · shortcut ⌦ → command delete · command selectAll · shortcut ⌘A → command selectAll · command goBack · shortcut ⌘[ → command goBack · shortcut ↩ → Edit Selection · shortcut ⌤ → Edit Selection
arrows              shape arrow · ContentsRows → arrow · service ArrowTargeting · tool arrow · shortcut A → tool arrow · overlay BindingHintsOverlay · willDelete
sticky-notes        shape sticky-note · tool sticky-note · shortcut N → tool sticky-note · DoubleClickPlacement → sticky-note · ValidationRules → sticky-note · ShapeChecklists → sticky-note · ShapeDetails → sticky-note · ShapeContextMenus → sticky-note · ContentsRows → sticky-note
ellipses            shape ellipse · tool ellipse · shortcut O → tool ellipse
task-cards          shape task-card · tool task-card · shortcut T → tool task-card · ValidationRules → task-card · ShapeDetails → task-card · ShapeContextMenus → task-card · ContentsRows → task-card · ShapeChecklists → task-card · ShapeDetails → task-card · ShapeContextMenus → task-card
validation          service ValidationEngine · overlay ValidationOverlay
detail-panel        service DetailPanelState · ShapeDetails
context-menus       service ContextMenuState · secondary-click menu
table-of-contents   service ContentsState
checklists          overlay ChecklistOverlay
validation-details  DetailStatuses
clipboard           service ClipboardState · command cut · shortcut ⌘X → command cut · command copy · shortcut ⌘C → command copy · command paste · shortcut ⌘V → command paste · ShapeContextMenus
rectangles          shape rectangle · tool rectangle · shortcut R → tool rectangle
polylines           shape polyline · tool polyline · shortcut L → tool polyline
eraser              tool eraser · shortcut E → tool eraser
titles              overlay TitleOverlay
ellipse-titles      ShapeTitles → ellipse
reordering          ShapeContextMenus
```

A horizontal's opt-in shows as what it contributes: `note.checklist(\.checklist)` is a
`ShapeChecklists` entry, a `ShapeDetails` entry and a `ShapeContextMenus` entry, which is why
task-cards has two of each of the last two (its own panel and menu, then the checklist's).

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
  SelectionTests, ArrowsTests, ValidationTests, DetailPanelTests, ChecklistsTests, ClipboardTests
  and ValidationDetailsTests import no real vertical (only these fixtures, and local test kinds), which
  proves those plugins are shape-agnostic.
- CanvasTests run the core with no plugin claiming the default tool, so it's the Hand there, and
  none claiming key strokes, so no key does anything; a test that presses, drags or selects shapes
  the way a user does installs `KeyboardPlugin()` and `SelectionPlugin()` first, as the app does.
- Tests drive the editor's host API, so they `@_spi(Host) import Canvas`.
- `renderBitmap(editor, size:)`, `pixel(_:at:)` and `changedPixels(_:_:in:)` check what's drawn.
- `Contributor(id:) { registrar in ... }` is a plugin written inline, and `editor.add(props)`
  inserts a shape in a transaction of its own.
- **The detail panel.** `editor.detailPanel?.layout(for:)` resolves a shape's header, tabs and
  sections without a view, and `statuses(for:)` its footer lines. `editor.shapeBinding(id, as:)`
  and `editor.frameBinding(id)` are the bindings a section gets: write through them and check the
  document. For the view, host `DetailPanelView` in an `NSHostingView` in an unshown `NSWindow`,
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
- **The clipboard.** A test that copies gives the clipboard a pasteboard of its own, so it never
  touches the user's: `ClipboardPlugin(pasteboard: NSPasteboard.withUniqueName())`, or
  `ShippedPlugins.makeEditor(pasteboard:)` (and `releaseGlobally()` it after). Two editors on one
  pasteboard are two boards copying and pasting between them.
- A test target is `Tests/<Name>Tests` with a `main.swift` that calls `runTests([...])`. Every
  `Suite` must be listed there (`test.sh` checks). `<M>Tests` may depend only on M, what M
  depends on, and the test-support and ui modules.
- **Boards.** `expectKindFixtures(kinds, in: registry, directory:)` (CanvasTesting) holds kinds to
  their fixtures ([Boards on disk](#boards-on-disk)); CompositionTests runs it for every shipped
  kind. CanvasTests read broken and scrambled boards (a seeded fuzz test), and CompositionTests'
  BoardDocumentTests open, save, revert and host boards with `BoardDocument.configuration` set as
  the app sets it. `./build.sh bench` builds BenchmarkTests in release and holds saving, opening,
  and a hover and a drag frame to their budgets on generated boards of 1,000 and 10,000 shapes;
  `./test.sh` runs it small, in debug, and only reports.
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
| `ToolIdle` / `ToolPointing` click-to-create | `Placement` (follow the pointer, or edit), used by place tools and the double-click claim. |
| `toolbarItems` with a decorative `kbd` | A key registered with the Keyboard horizontal (`shortcut:`), collision-checked, that the canvas answers and the tooltip names. |
| `install*Lifecycle(editor)` side effects | `registrar.willDelete` inside transactions; `EditorService` for per-editor state. |
| `module.json` + ESLint DAG + barrel `index.ts` | `Package.swift` with layers + `build.sh audit` + the compiler; `public` is the barrel. |
| `plugins.config.ts` | `ShippedPlugins.all` in Composition. |

## Not built yet

Each of these adds to the design without changing what plugins are written against.

- **More of change sets:** each commit already says what it added, changed and removed
  (`ChangeSet`, which services get with `documentDidChange`); what's left is who made it (the user,
  an agent) and the records before and after. Undo, an agents' CLI and sync build on them.
- **An arrow end bound to a shape that isn't there** (deleted outside a transaction, or kept aside)
  is drawn at the origin; a binding should keep a point to fall back on.
- **Undo.** `transact` is already the one mutation path. The editor will open an undo group on
  each press and when editing begins, close it on release and when editing ends, and register each
  group's before and after with `UndoManager`. Panel edits are one transaction per keystroke or
  step today; grouping them (per focused field, per stepper or color drag) hooks into
  `ShapeBinding`'s two write paths.
- **More document hooks** (before/after create and change), and **document-scoped services** for
  several windows on one board.
- **An editing view hearing about outside changes** to its shape (needed once undo exists).
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
- **More of going back**: going forward again (⌘]), and a step keeping what the table of contents
  listed, so Show All survives a trip back.
- **More of the keyboard**: a window listing every shortcut; menu items that take their key
  equivalents from Keyboard, so the View menu's zoom keys and Edit › Select All's ⌘A are declared
  once; and keys the user remaps.
- **More of the table of contents**: nested shapes (a shape's container as the default
  `nestedUnder`), with each row's disclosure remembered (every nested row starts collapsed today);
  dragging rows to restack their shapes; per-kind zoom targets
  and click actions (data-canvas's `getZoomConfig` and `onClick`); Return editing the selected
  shape; and arrow rows that name the shapes they join.
- **More of the clipboard**: pasting what other apps put on the pasteboard (text as a note, an
  image) and giving them a text or image version of copied shapes; pasting at the pointer
  (tldraw's preference, and ⌥); Duplicate (⌘D) and ⌥-dragging a copy, on the same copying; and
  undo grouping a cut or a paste into one step.
- **More of the context menu**: items for empty canvas (Paste, Select All), through a point of
  their own; key equivalents and symbols on items; and the items everyone expects, such as Delete
  and Duplicate, once a plugin owns them.
- **More of the detail panel**: editing several selected shapes at once (it shows "N Shapes"
  today); every-shape sections over the
  record (not only every-box ones over the frame), and every-box overrides such as an aspect lock;
  remembering the chosen tab and collapsed sections across launches (`DetailTabID.name` is stable
  for that); and marking the row a validation issue is about (`ValidationIssue.field`).
