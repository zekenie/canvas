@_spi(Host) import Canvas
import CanvasTesting
import ContextMenus
import CoreGraphics
import Keyboard
import Moving
import Selection
import SlashCommands
import TableOfContents
import TestKit

// Fixtures only: CanvasTesting's boxes, discs and tags, corrals (they hold shapes, as a frame does), pockets
// (they own a board, as a subboard does), links, cards (they're edited) and freezing, so every test here
// shows Moving knows no real kind. Commands run headlessly, through the slash commands' service, with the
// one shape a line's pill would give them.

/// The fixtures, freezing (every refusal in `log`), slash commands, the table of contents and Moving, then `more`.
@MainActor func movingPlugins(log: RefusalLog = RefusalLog(), _ more: [any CanvasPlugin] = []) -> [any CanvasPlugin] {
    [KeyboardPlugin(), FixturesPlugin(), CorralsPlugin(), PocketsPlugin(), LinksPlugin(), CardsPlugin(), FreezingPlugin(log: log), ContextMenusPlugin(), SlashCommandsPlugin(),
     TableOfContentsPlugin(), MovingPlugin()] + more
}

/// An editor of `file` with those plugins.
@MainActor func movingHarness(_ file: CanvasFile = CanvasFile(), log: RefusalLog = RefusalLog(), _ more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try EditorHarness(plugins: movingPlugins(log: log, more), file: file)
}

/// The same, with the keyboard and the selection first, so several rows can be selected and dragged together.
@MainActor func droppingHarness(_ file: CanvasFile = CanvasFile(), log: RefusalLog = RefusalLog(), _ more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try EditorHarness(plugins: [SelectionPlugin()] + movingPlugins(log: log, more), file: file)
}

// MARK: A pin

/// A shape bound to another as an arrow's end is (`ShapeReferencing`), drawn at that shape's middle: let
/// go of it (the shape deleted, or moved to another board), it stays where it's drawn, that middle as
/// the shape was then, kept in `at`. What tells where a move let go of a binding.
struct Pin: ShapeProps {
    static let kind: ShapeKind = "pin"
    static let properties = Properties<Pin> {
        Property("target", \.target)
        Property("at", \.at)
    }
    var target: ShapeID?
    var at: CGPoint
}

extension Pin {
    init() { self.init(target: nil, at: .zero) }
}

struct PinDefinition {}

extension PinDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Pin>, in context: RenderContext) {}

    func geometry(of shape: ShapeRecord<Pin>, in context: ShapeContext) -> ShapeGeometry {
        let at = shape.props.target.flatMap { context.geometry(of: $0)?.bounds }.map { CGPoint(x: $0.midX, y: $0.midY) } ?? shape.props.at
        return ShapeGeometry(outline: [at], bounds: CGRect(origin: at, size: .zero), isClosed: false)
    }
}

extension PinDefinition: ShapeReferencing {
    func remappingReferences(of shape: ShapeRecord<Pin>, _ map: (ShapeID) -> ShapeID?, in context: ShapeContext) -> Pin? {
        guard let target = shape.props.target else { return shape.props }
        if let kept = map(target) { return Pin(target: kept, at: shape.props.at) }
        guard let bounds = context.geometry(of: target)?.bounds else { return nil }
        return Pin(target: nil, at: CGPoint(x: bounds.midX, y: bounds.midY))
    }
}

/// Pins ("pin"), no tool.
struct PinsPlugin: CanvasPlugin {
    var id: PluginID { "pins" }
    func register(into registrar: inout PluginRegistrar) { registrar.shape(PinDefinition()) }
}

// MARK: Boards of shapes

/// A box, 100 × 100 unless said, its top-left at (x, y).
func box(_ id: ShapeID, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 100, in container: ShapeID? = nil) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Box(CGRect(x: x, y: y, width: size, height: size)))).copy(as: id, container: container)
}

func corral(_ id: ShapeID, _ frame: CGRect, in container: ShapeID? = nil) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Corral(frame))).copy(as: id, container: container)
}

/// A pocket, 240 × 160 at (x, y).
func pocket(_ id: ShapeID, _ x: CGFloat, _ y: CGFloat, in container: ShapeID? = nil) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Pocket(CGRect(x: x, y: y, width: 240, height: 160)))).copy(as: id, container: container)
}

func link(_ id: ShapeID, _ from: ShapeID?, _ to: ShapeID?) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Link(from: from, to: to)))
}

func board(_ records: AnyShapeRecord...) -> CanvasDocument { CanvasDocument(shapes: records) }

/// A box's frame, 100 × 100 unless said, at (x, y).
func at(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat = 100, _ height: CGFloat = 100) -> CGRect { CGRect(x: x, y: y, width: width, height: height) }

extension EditorHarness {
    /// Runs a command on a shape with one shape typed after its name, as a line's one pill gives it.
    @discardableResult
    func run(_ name: String, on id: ShapeID, with target: ShapeID) -> Bool {
        editor.slashCommands?.run(name, on: id, with: SlashArguments([.shape(target, label: "Target")])) ?? false
    }

    /// Whether the command a shape offers by that name takes `target` (false if it offers none).
    func admits(_ name: String, on id: ShapeID, _ target: ShapeID) -> Bool {
        editor.slashCommands?.command(named: name, for: id)?.admits(target) ?? false
    }

    /// Runs a command for the shapes selected (the command bar's target) with one shape typed after its name.
    @discardableResult
    func run(_ name: String, onSelection ids: [ShapeID], with target: ShapeID) -> Bool {
        editor.slashCommands?.run(name, for: .selection(ids), with: SlashArguments([.shape(target, label: "Target")])) ?? false
    }

    /// Whether the command the shapes selected offer by that name takes `target` (false if they offer none).
    func admits(_ name: String, onSelection ids: [ShapeID], _ target: ShapeID) -> Bool {
        editor.slashCommands?.command(named: name, for: .selection(ids))?.admits(target) ?? false
    }

    /// Drags the rows of `ids` (selected first, when there are several, as the list drags every selected row)
    /// and drops them on `row`, at `zone`: whether the list took the drop.
    @discardableResult
    func drop(_ ids: [ShapeID], on row: ShapeID, _ zone: ContentsDropZone) -> Bool {
        guard let state = editor.tableOfContents, let first = ids.first else { return false }
        if ids.count > 1 { editor.selectedShapeIDs = ids }
        guard state.beginDrag(from: first) else { return false }
        return state.drop(on: ContentsDropTarget(row: row, zone: zone))
    }

    /// Whether the list would take a drag of `ids`' rows dropped on `row`, at `zone`.
    func admitsDrop(_ ids: [ShapeID], on row: ShapeID, _ zone: ContentsDropZone) -> Bool {
        guard let state = editor.tableOfContents, let first = ids.first else { return false }
        if ids.count > 1 { editor.selectedShapeIDs = ids }
        guard state.beginDrag(from: first) else { return false }
        return state.admits(ContentsDropTarget(row: row, zone: zone))
    }

    /// A shape's box, wherever it is in the file.
    func frame(of id: ShapeID) -> CGRect? { file.record(id)?.box }

    /// The container a shape is in, on whichever board of the file it's on.
    func container(of id: ShapeID) -> ShapeID? {
        file.board(containing: id).flatMap { file[$0].container(of: id, containingKinds: editor.registry.containingKinds) }
    }

    /// Freezes shapes on the board shown (or thaws them, with `false`) in a step named Freeze, so that what's
    /// undone next tells whether a move made a step.
    func freeze(_ ids: [ShapeID], _ frozen: Bool = true) {
        editor.undoHistory.group("Freeze") { editor.freeze(ids, frozen) }
    }
}

/// The file, and the file as a board file's bytes: what undo and redo must come back to.
@MainActor func expectFile(_ h: EditorHarness, _ expected: CanvasFile, _ message: String, file: StaticString = #fileID, line: UInt = #line) throws {
    expectEqual(h.file, expected, message, file: file, line: line)
    let codec = BoardCodec(registry: h.editor.registry)
    expectEqual(try codec.encode(h.file), try codec.encode(expected), "\(message), as a file", file: file, line: line)
}
