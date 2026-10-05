import Canvas
import CanvasTesting
import ContextMenus
import CoreGraphics
import Foundation
import Keyboard
import Selection
import SlashCommands
import TestKit
import Transform

// Fixtures only: CanvasTesting's corrals (they hold shapes, as a frame does), pockets (they own a board,
// as a subboard does), boxes, discs and links, so every test here shows Transform knows no real kind. A
// corral turns into a pocket the way a frame turns into a subboard, and boxes turn into discs through a
// channel of the tests' own, which holds the mechanism apart from containers.

/// What a title is to a frame and a subboard: an added property that corrals and pockets both hold, so a
/// turn carries it from one to the other.
enum Tagline {}
extension Tagline: ShapeProperty {
    static let key: PropertyKey = "tagline"
    static var defaultValue: String? { nil }
}

/// A pocket's size: what a subboard's is.
let pocketSize = CGSize(width: 240, height: 160)

/// Corrals and pockets hold a tagline.
func taglines() -> Contributor {
    Contributor(id: "taglines") { r in
        r.declare(Tagline.self)
        r.optIn(Corral.self, to: Tagline.self)
        r.optIn(Pocket.self, to: Tagline.self)
    }
}

/// Corrals offer the container channel, as a frame does, and pockets take it, as a subboard does: a
/// pocket's size at the corral's corner, holding on its board what the corral held.
func corralsTurnIntoPockets() -> Contributor {
    Contributor(id: "turning") { r in
        r.turnable(Corral.self, through: ContainerChannel.self)
        r.turnable(into: Pocket.self, through: ContainerChannel.self, label: "Pocket") { container, transaction in
            guard transaction.turn(container.id, into: Pocket(CGRect(origin: container.frame.origin, size: pocketSize))) else { return }
            transaction.move(container.held, toBoardOwnedBy: container.id)
        }
    }
}

/// A channel of the tests' own: only a box may offer it, and what it hands over is the box's id, if the box
/// is less than 100 wide; a wider one has nothing to hand over.
enum BoxChannel {}
extension BoxChannel: TransformChannel {
    static var name: String { "box" }

    static func admits(_ kind: TransformKind) -> Bool { kind.kind == Box.kind }

    static func source(of id: ShapeID, in transaction: Transaction) -> ShapeID? {
        transaction.document[id].flatMap { ($0.box?.width ?? 0) < 100 ? id : nil }
    }
}

/// A channel that admits every kind, as a channel does by default: what it hands over is the shape's id.
enum LooseChannel {}
extension LooseChannel: TransformChannel {
    static var name: String { "loose" }

    static func source(of id: ShapeID, in transaction: Transaction) -> ShapeID? { id }
}

/// Boxes offer the box channel, and discs take it: a box becomes a disc on its own frame.
func boxesTurnIntoDiscs() -> Contributor {
    Contributor(id: "disc-turning") { r in
        r.turnable(Box.self, through: BoxChannel.self)
        r.turnable(into: Disc.self, through: BoxChannel.self, label: "Disc") { id, transaction in
            guard let frame = transaction.document[id]?.box else { return }
            transaction.turn(id, into: Disc(frame))
        }
    }
}

/// The shapes a test's target was asked to turn, in order.
@MainActor final class CallLog {
    var ids: [ShapeID] = []
}

/// What the app has around transforms (the keys, the selection, the context menu and slash commands),
/// and the fixtures, with no transform: those are `more`, or `corralsTurnIntoPockets()` for the usual one.
@MainActor func transformBase(log: RefusalLog = RefusalLog()) -> [any CanvasPlugin] {
    [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), SlashCommandsPlugin(), TransformPlugin(),
     FixturesPlugin(), CorralsPlugin(), PocketsPlugin(), LinksPlugin(), NamingPlugin(), FreezingPlugin(log: log), taglines()]
}

/// The base, corrals that turn into pockets, then `more`.
@MainActor func transformPlugins(_ more: [any CanvasPlugin] = [], log: RefusalLog = RefusalLog()) -> [any CanvasPlugin] {
    transformBase(log: log) + [corralsTurnIntoPockets()] + more
}

/// An editor of `file` with those plugins.
@MainActor func transformHarness(_ more: [any CanvasPlugin] = [], file: CanvasFile = CanvasFile(), log: RefusalLog = RefusalLog()) throws -> EditorHarness {
    try EditorHarness(plugins: transformPlugins(more, log: log), file: file)
}

// MARK: Boards of shapes

func box(_ id: ShapeID, x: CGFloat = 0, y: CGFloat = 0, in container: ShapeID? = nil) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Box(CGRect(x: x, y: y, width: 40, height: 30)))).copy(as: id, container: container)
}

func corral(_ id: ShapeID, _ frame: CGRect, in container: ShapeID? = nil) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Corral(frame))).copy(as: id, container: container)
}

func link(_ id: ShapeID, _ from: ShapeID?, _ to: ShapeID?) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Link(from: from, to: to)))
}

func board(_ records: AnyShapeRecord...) -> CanvasDocument { CanvasDocument(shapes: records) }

func ids(_ document: CanvasDocument) -> [ShapeID] { document.shapes.map(\.id) }

/// A plugin written inline.
func plugin(_ id: PluginID, _ body: @escaping @MainActor (inout PluginRegistrar) -> Void) -> Contributor { Contributor(id: id, body) }

extension EditorHarness {
    /// A shape's props, wherever it is in the file.
    func props<P: ShapeProps>(_ id: ShapeID, as _: P.Type) -> P? { file.record(id)?.typed(as: P.self)?.props }

    /// The file's board a shape owns.
    func contents(of owner: ShapeID) -> CanvasDocument { file[BoardID(owner: owner)] }
}

/// The file, and the file as a board file's bytes: what undo and redo must come back to.
@MainActor func expectFile(_ h: EditorHarness, _ expected: CanvasFile, _ message: String, file: StaticString = #fileID, line: UInt = #line) throws {
    expectEqual(h.file, expected, message, file: file, line: line)
    let codec = BoardCodec(registry: h.editor.registry)
    expectEqual(try codec.encode(h.file), try codec.encode(expected), "\(message), as a file", file: file, line: line)
}

/// A shape of `kind` a board keeps aside, as one from a newer version of its kind: read from a board, as
/// nothing else makes one.
@MainActor func keptAside(_ kind: ShapeKind, id: ShapeID, in registry: Registry) throws -> AnyShapeRecord {
    let json = """
    { "format" : 1, "schema" : { "\(kind.rawValue)" : 99 }, "shapes" : [
      { "id" : "\(id)", "kind" : "\(kind.rawValue)", "index" : "a0", "props" : { "frame" : [[0, 0], [10, 10]] } } ] }
    """
    let record = try require(BoardCodec(registry: registry).decode(Data(json.utf8)).document[id])
    expect(record.isOpaque)
    return record
}
