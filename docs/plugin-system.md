# The plugin system

Everything on the canvas comes from a plugin: sticky notes, ellipses, arrows, validation, even the
examples. The core (`Sources/Canvas`) knows how to hold shapes, run tools, draw, and wire plugins
together, and nothing about any particular shape or concern. Its one built-in tool is Select, which
also pans, moves shapes, and drives handles and editing for whatever kinds offer them.

This is the same system as data-canvas's `definePlugin`, in Swift. [The last section](#coming-from-data-canvas)
maps one onto the other.

- [Four nouns](#four-nouns)
- [Horizontal and vertical](#horizontal-and-vertical)
- [The module graph](#the-module-graph)
- [A vertical plugin](#a-vertical-plugin)
- [Tools and sessions](#tools-and-sessions)
- [A horizontal plugin](#a-horizontal-plugin)
- [Capabilities](#capabilities)
- [The editor, the document, and drawing](#the-editor-the-document-and-drawing)
- [The registry](#the-registry)
- [Testing plugins](#testing-plugins)
- [Coming from data-canvas](#coming-from-data-canvas)
- [Not built yet](#not-built-yet)

## Four nouns

| | What it is | Example |
|---|---|---|
| **Kind** | A plain value type holding a shape's data. It names itself once, with `static let kind`. | `struct StickyNote: BoxShapeProps { frame, text }` |
| **Definition** | Stateless behavior for a kind: how it draws, where it is, how it's hit, what else it can do. | `StickyNoteDefinition`, conforming to `ShapeDefinition` and `Editable` |
| **Plugin** | A value that says what it adds, in `register(into:)`. | `struct StickyNotesPlugin: CanvasPlugin` |
| **Extension point** | A typed slot some plugin declares and other plugins fill. The type is the key. | `enum ValidationRules: ExtensionPoint` |

Two more things hold them together:

- The **registry** is built once from the plugin list, checked (every collision is an error), and
  then frozen.
- The **editor** (`CanvasEditor`) is the headless brain: the document, the camera, selection,
  tools, input and drawing. `CanvasView` only turns `NSEvent`s into editor calls, through a host
  API that plugins can't see.

## Horizontal and vertical

A **vertical** plugin is a feature: a shape kind and the tool that places it, or a tool on its own.
Sticky notes, ellipses, arrows, rectangles and the eraser are verticals.

A **horizontal** plugin is a concern that cuts across kinds. It declares an extension point, and any
kind can take part by contributing to it. Validity is the canonical example: *a shape can be valid
or invalid* is horizontal; *an empty sticky note is invalid* is one vertical opting in. Titles are
another. The horizontal owns the contract, the engine, and whatever it draws. Shapes never know
they're invalid; the validation plugin outlines them.

Opting in goes in one of two directions:

- **The vertical imports the horizontal** and contributes from inside its own `register`.
  StickyNotes does this for Validation: `note.validate { ... }`.
- **A bridge imports both**, and neither knows the other. `EllipseTitles` gives ellipses a title,
  though Ellipses has never heard of titles and Titles has never heard of ellipses.

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
.target(name: "StickyNotes", dependencies: ["Canvas", "Validation"]),                  // layer: vertical
.target(name: "EllipseTitles", dependencies: ["Canvas", "Ellipses", "Titles"], path: "Examples/EllipseTitles"), // layer: bridge
```

| Layer | May depend on | Modules |
|---|---|---|
| foundation | foundation | Geometry, Canvas (the core) |
| ui | foundation | CanvasUI (the AppKit view and the SwiftUI toolbar) |
| horizontal | foundation, horizontal | Validation, Titles |
| vertical | foundation, horizontal | Arrows, StickyNotes, Ellipses, Rectangles, Eraser |
| bridge | foundation, horizontal, vertical | EllipseTitles |
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
- **Package.swift is real SwiftPM.** The audit evaluates it with SwiftPM's own `PackageDescription`
  and fails if SwiftPM would see a different graph, so Xcode opens the same project.

On top of that, the compiler sees only a module's dependency closure (`-I`), so nothing outside
it can be named at all, and every module compiles with `MemberImportVisibility`, so using a member
from a module you didn't import is an error rather than a silent transitive edge. (Importing a
transitive dependency without declaring it is what the import check above catches.)

**Adding a module:** make its directory (`Sources/X`, or `Examples/X` with `path:`), add its line to
`Package.swift` with a layer, and add its tests. Every non-app module is compiled by `./test.sh`,
even before anything depends on it. **Shipping it:** add it to Composition's dependencies in
`Package.swift`, import it in `Sources/Composition/ShippedPlugins.swift`, and add its plugin to
`ShippedPlugins.all`, whose order is the toolbar's.

## A vertical plugin

This is the whole of the smallest one, [`Examples/Rectangles`](../Examples/Rectangles/Rectangles.swift):

```swift
import AppKit
import Canvas

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

- **The kind is its props.** `ShapeProps` values are `Codable`, `Equatable` and `Sendable`.
  `BoxShapeProps` adds a `frame`, and with it most behavior for free. The document stores each
  shape as an `AnyShapeRecord` (id, kind, props). Definitions get it typed, as `ShapeRecord<Rectangle>`.
- **The definition is stateless.** For a box kind, only `render` is required. The rest has defaults:

  | Requirement | Default |
  |---|---|
  | `geometry(of:in:)` | the frame (box kinds); every other kind must say |
  | `hitTest(_:on:in:)` | inside the geometry's closed outline |
  | `indicatorPath(of:in:)` | the geometry's outline (hover, selection and target outlines) |

  `geometry` is the one source of truth. Override it and hit testing, the outline and arrows all
  follow. Override `hitTest` or `indicatorPath` only when you can do better; Ellipses does both (an
  exact hit test, a smooth outline).
- **Conform in an extension**, as above, for `ShapeDefinition` and its capabilities, `Tool`,
  `Session` and `EditorService`. Swift flags a member that *nearly* matches a defaulted requirement
  (a wrong label, a missing return type) only in the extension that declares the conformance, and
  the build fails on it. Declared on the type, a near miss compiles and the default silently runs.
- **The kind is stated once.** Everything registered inside `registrar.shape(...) { rectangle in ... }`
  is stamped with `"rectangle"`: the tool's id, its report line, and any horizontal contributions.
- **Placements create box shapes** for place tools and the double-click claim.
  `placement(size:props:)` centers a new shape on the press, selects it, and lets it follow the
  pointer until release. `editingPlacement` opens it for editing instead, and exists only for
  `Editable` kinds, a restriction the compiler checks. Any tool can also insert a shape itself,
  with `editor.transact { $0.insert(record) }`, as the arrow tool does.

What a real vertical adds on top ([StickyNotes](../Sources/StickyNotes/StickyNotes.swift)):

```swift
registrar.shape(StickyNoteDefinition()) { note in
    let place = note.editingPlacement(size: NoteStyle.size) { StickyNote() }
    note.tool(label: "Note", systemImage: "note.text", shortcut: "n", placing: place)
    note.createOnDoubleClick(place)          // double-clicking empty canvas places a note
    note.validate { shape, _ in              // opts into the Validation horizontal
        shape.props.text.allSatisfy(\.isWhitespace) ? [.warning("This note is empty.")] : []
    }
}
```

## Tools and sessions

A **tool** handles what happens before a press: hover, the press itself, and which cursor to
show. It's a class with one instance per editor, so it can keep state. A **session** owns one
press-drag-release. It lives on the editor, not the tool, so it outlives tool switches. A place tool
switches back to select and keeps dragging its new shape; the arrow tool drags first and switches
after.

[`Examples/Eraser`](../Examples/Eraser/Eraser.swift) is a tool with no shape:

```swift
import Canvas
import CoreGraphics

extension ToolID {
    public static let eraser: ToolID = "eraser"
}

public struct EraserPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "eraser" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.tool(ToolDescriptor(id: .eraser, label: "Eraser", systemImage: "eraser", shortcut: "e")) { _ in EraserTool() }
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
  running), `pointerExited`, `modifiersChanged`, `cursor(in:)`. All but `pointerDown` have defaults.
- **`Session`**: `drag`, `end`, `cancel` (Escape; return true if you cancelled),
  `modifiersChanged`, `cursor(in:)`, `hidesSelectionIndicator`. A session can hand over to another by
  setting `editor.session` (pressing an arrow handle becomes dragging it). A session that sets
  `editor.hintedShapeID` clears it when it ends.
- **Input**: tools see `Pointer` values, never `NSEvent`s. A `Pointer` has `view` (view points)
  and `world` (world units) locations, `modifiers` and `clickCount`. `editor.pointerSpeed` is
  smoothed like tldraw's. `editor.effectiveModifiers` counts a key released in the last 150 ms as
  still held, so letting go of ⌥ and the mouse together doesn't undo ⌥.
- **Time**: timers go through `editor.scheduler`. Tests swap in a `ManualScheduler` and run time by
  hand, which is how the arrows' 600/320/150 ms timers are pinned to the millisecond.
- **Shortcuts** are single unmodified keys, handled by the canvas (so typing in a note never
  switches tools). A shortcut or tool id used twice is a registry error, including the core's `V`.
- **The toolbar** is the registry's tools in plugin-list order, after the core's Select. It follows
  `editor.currentToolID`, which is observable.
- **Redrawing**: the core redraws whenever the document, camera, selection, hover, tool or session
  changes. A plugin whose drawn state changes some other way (on a timer, say) calls
  `editor.setNeedsDisplay()`.

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

/// The hovered shape's title, just below it.
struct TitleOverlay: CanvasOverlay {
    var space: OverlaySpace { .view }       // drawn in view points, after the handles

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

## Capabilities

Some behavior belongs to a kind itself rather than to a concern others can join. That's a
**capability**: a protocol refining `ShapeDefinition`, found by the core with `as?`.

| Capability | For | Used by |
|---|---|---|
| `Editable` | Edited in place: double-click, Return, or an editing placement. Supplies an `NSView` laid over the shape; writes go through `EditContext.update`. | StickyNotes |
| `HandleProviding` | Draggable handles on the selected shape. The core finds, draws and hit-tests them; `pressHandle` returns `.drag` or `.consumed`, and `dragSession` does the dragging. | Arrows |
| `CustomTranslation` | Moving the shape with its own session instead of by its frame. A kind without a frame needs this to be movable at all. | Arrows |
| `PaintOrderAnchored` | Painted just above another shape, and never raised when pressed. | Arrows (above the shapes they join) |

The rule of thumb: behavior intrinsic to a kind is a capability; behavior anyone can add, to any
kind, from any plugin, is an extension point.

## The editor, the document, and drawing

- **The document is a value.** `CanvasDocument` holds every shape, back to front. The only way to
  change it is `editor.transact { tx in ... }`: `insert`, `update` (typed with `as:`),
  `bringToFront`, `delete`. A transaction commits once, if anything changed, and bumps
  `editor.revision`. Transactions don't nest. Undo (not built yet) will group commits: everything
  from a press to its release, and everything while a shape is being edited, will be one step.
- **`willDelete`** handlers run inside the deleting transaction, before anything is removed, so a
  plugin can let go of shapes that are about to disappear (arrows bake their curve there). They may
  delete more; each shape's handlers run once.
- **Selection, hover and hint** (`selection`, `hovered`, `hintedShapeID`) always name a shape that
  exists. `editingShapeID` is the shape being edited.
- **Drawing**, back to front: background and grid; shapes in paint order (culled by frame); the
  hover, selection and target outlines in one stroke at a constant screen width; world overlays;
  the selected shape's handles; view overlays. Each shape and overlay draws with a fresh graphics
  state. Sizes meant as view points are divided by `zoom` in world space.
- **The view.** `CanvasView` (CanvasUI) is the only AppKit in the loop. It converts events, hosts
  the editing view over its shape, and draws the editor, all through the editor's `@_spi(Host)`
  API. Only the app and tests can import CanvasUI, and no plugin can see the host API, so no
  plugin can reach around the editor.

## The registry

`Registry(plugins:)` runs every plugin's `register(into:)` once, after the core's own plugin (the
select tool). It then checks everything and throws on:

| Error | When |
|---|---|
| `duplicatePlugin` | The same plugin id twice. |
| `ownerNotInstalled` | A contribution to a point whose owner isn't in the list. |
| `unknownKind` | A contribution for a kind no plugin registers. |
| `conflict` | Two claims to the same key: a kind, a tool id, a shortcut, a service type, the double-click claim, or a key in any `KeyedExtensionPoint`. |

Once built, it's frozen and handed to the editor. The app's list is `ShippedPlugins.all` in
[Composition](../Sources/Composition/ShippedPlugins.swift), and a test checks it registers.
`registry.report` prints who contributes what: the runtime half of the graph, pinned by a test.

```
core            tool select [v]
arrows          shape arrow · service ArrowTargeting · tool arrow [a] · overlay BindingHintsOverlay · willDelete
sticky-notes    shape sticky-note · tool sticky-note [n] · double-click sticky-note · ValidationRules → sticky-note
ellipses        shape ellipse · tool ellipse [o]
validation      service ValidationEngine · overlay ValidationOverlay
...
```

## Testing plugins

Tests are plain executables built on a small macro-free kit (swift-testing's macros don't work
with this toolchain, and there's no XCTest). `./test.sh` builds and runs them all.
`TEST_FILTER=substring ./test.sh` runs the matching tests.

```swift
@MainActor let rectangleTests = Suite("Rectangles", [
    test("R and a press place a rectangle") {
        let h = try EditorHarness(plugins: [RectanglesPlugin()])
        h.key("r")
        h.press(at: CGPoint(x: 300, y: 200))
        h.release()
        let rectangle = try require(h.editor.document.shapes.first)
        expectEqual(rectangle.box, CGRect(x: 220, y: 150, width: 160, height: 100))
    },
])
```

- `EditorHarness` (CanvasTesting) drives a headless editor like a user: `move`, `press`, `drag`
  (optionally at a speed), `release`, `hold(modifiers)`, `key`, `escape`, `wait(ms)`. One clock
  drives both event timestamps and the `ManualScheduler`, so pointer speed and timers agree.
- `FixturesPlugin` and `CardsPlugin` (CanvasTesting) give core and horizontal tests shapes to work
  with (`Box`, `Disc`, `Tag`, and the editable `Card`), so they never depend on a real vertical.
  ArrowsTests and ValidationTests import no real vertical (only these fixtures, and a local test
  kind), which proves those plugins are shape-agnostic.
- Tests drive the editor's host API, so they `@_spi(Host) import Canvas`.
- `renderBitmap(editor, size:)` and `pixel(_:at:)` check what's drawn.
- A test target is `Tests/<Name>Tests` with a `main.swift` that calls `runTests([...])`. Every
  `Suite` must be listed there (`test.sh` checks). `<M>Tests` may depend only on M, what M
  depends on, and the test-support and ui modules.
- **Arrow behavior is pinned to the proof of concept.** CompositionTests replays 23 arrow
  scenarios through `CanvasView` with real events and compares where every arrow ends up, byte for
  byte, with a transcript recorded from the POC. It also compares nine renders pixel for pixel:
  the welcome board, hover and target outlines, binding hints mid-drag, handles and their halos,
  zoomed out. The same replay code (`Tests/CompositionTests/Replay.swift`) drives the POC when
  recording and the app when testing. The recordings come only from the POC:
  `scripts/record-poc-fixtures.sh` rebuilds them from commit 804db97, and re-running it should
  change nothing. Never regenerate them from the app to make a change pass.

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
| `ToolIdle` / `ToolPointing` click-to-create | `Placement` (follow the pointer, or edit), used by place tools and the double-click claim. |
| `toolbarItems` with a decorative `kbd` | `ToolDescriptor` with a real, collision-checked shortcut. |
| `install*Lifecycle(editor)` side effects | `registrar.willDelete` inside transactions; `EditorService` for per-editor state. |
| `module.json` + ESLint DAG + barrel `index.ts` | `Package.swift` with layers + `build.sh audit` + the compiler; `public` is the barrel. |
| `plugins.config.ts` | `ShippedPlugins.all` in Composition. |

## Not built yet

Each of these adds to the design without changing what plugins are written against.

- **Persistence.** Props are already `Codable`, so a document codec is an addition. Keeping shapes
  whose plugin isn't installed needs two small core changes: an `AnyShapeRecord` initializer for
  opaque props that carries its own kind, and relaxing the installed-kind checks in
  `CanvasEditor.init` and `Transaction.insert`. Drawing and hit testing already skip kinds with
  no definition.
- **Undo.** `transact` is already the one mutation path. The editor will open an undo group on
  each press and when editing begins, close it on release and when editing ends, and register each
  group's before and after with `UndoManager`.
- **More document hooks** (before/after create and change), and **document-scoped services** for
  several windows on one board.
- **An editing view hearing about outside changes** to its shape (needed once undo exists).
- **Canvas features**: multi-select (a set of selected shapes, keeping `selection` as "the only
  selected shape", as tldraw does, so plugins keep working), resize, marquee, snapping, and
  hierarchical tool states once the select tool has more than a handful of sessions.
- **More horizontals** from data-canvas: describe, search, table of contents, inspectors,
  commands. Each is an extension point in its own plugin.
