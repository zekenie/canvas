import Canvas
import CanvasRPC
import CoreGraphics
import Foundation

// What the file keeps of a drawing (the contract's Drawings): for each drawing by its name, the board its top went on and
// every shape it made, by id, with the program's key for it and what it last wrote on it (its properties and its place),
// so a program's next pass finds its shapes by key, and anyone can ask what a person changed since (`changes(from:)`).
// Nothing is kept on the shapes. Draw keeps none itself: the plugin that owns drawings does (`DrawRecords`, Drawings'), and
// `apply` and `draw --drawing` read and write through it.

/// One shape as a drawing last wrote it, or as it is now: its kind, its properties (its own and its added values, as the
/// file holds them: `record.propertiesJSON`, less where it is), the board it is on, the container it is in, and its box.
public struct DrawnState: Codable, Equatable, Sendable {
    public var kind: String
    public var props: JSONObject
    /// `root`, or the id of the shape that holds the board.
    public var board: String
    public var container: String?
    /// `[x, y, width, height]`, the box it stores, world units; none for a shape with no box (an arrow).
    public var box: [Double]?

    public init(kind: String, props: JSONObject, board: String, container: String?, box: [Double]?) {
        self.kind = kind
        self.props = props
        self.board = board
        self.container = container
        self.box = box
    }

    /// A shape as the file holds it now; nil for one the file doesn't have.
    @MainActor
    public static func of(_ id: ShapeID, in file: CanvasFile, registry: Registry) -> DrawnState? {
        guard let board = file.board(containing: id), let record = file.record(id) else { return nil }
        return of(record, on: board, registry: registry)
    }

    /// A shape as `record` has it, on `board`; nil for one kept aside.
    @MainActor
    public static func of(_ record: AnyShapeRecord, on board: BoardID, registry: Registry) -> DrawnState? {
        guard !record.isOpaque else { return nil }
        var props = record.propertiesJSON ?? [:]
        let schema = KindSchema(registry.schema(for: record.kind) ?? JSONSchema([:]))
        for key in props.keys where schema.holdsPlace(key) { props[key] = nil }
        let box = record.box.map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] }
        return DrawnState(kind: record.kind.rawValue, props: props, board: board.description, container: record.container?.description, box: box)
    }

    /// How `self` (a shape now) differs from `before` (what a drawing last wrote): `moved`, `resized`, `frame` (another
    /// container), `board`, `kind`, and each property whose value differs, by name, in that order and each once.
    public func changes(from before: DrawnState) -> [String] {
        var said: [String] = []
        if kind != before.kind { said.append("kind") }
        if board != before.board { said.append("board") }
        if container != before.container { said.append("frame") }
        if let now = box, let then = before.box, now.count == 4, then.count == 4 {
            if now[0] != then[0] || now[1] != then[1] { said.append("moved") }
            if now[2] != then[2] || now[3] != then[3] { said.append("resized") }
        } else if (box == nil) != (before.box == nil) {
            said.append("moved")
        }
        for key in Set(props.keys).union(before.props.keys).sorted() where props[key] != before.props[key] { said.append(key) }
        return said
    }
}

/// What a drawing made, as the file keeps it: the board its top went on, and each shape it made by its id (a shape the file
/// no longer holds too: what the drawing made that is gone), with the program's key and what the drawing last wrote.
public struct DrawingRecord: Codable, Equatable, Sendable {
    public struct Shape: Codable, Equatable, Sendable {
        public var key: String
        public var wrote: DrawnState

        public init(key: String, wrote: DrawnState) {
            self.key = key
            self.wrote = wrote
        }
    }

    /// `root`, or the id of the shape that holds the board.
    public var board: String
    /// By id.
    public var shapes: [String: Shape]

    public init(board: String, shapes: [String: Shape] = [:]) {
        self.board = board
        self.shapes = shapes
    }

    /// The id of the shape a key names, among those the drawing made.
    public var idsByKey: [String: ShapeID] {
        var ids: [String: ShapeID] = [:]
        for (id, shape) in shapes { if let uuid = UUID(uuidString: id) { ids[shape.key] = ShapeID(uuid) } }
        return ids
    }
}

/// How drawings are kept: read a drawing by its name (nil for one the file hasn't), write one (nil takes it off), and list
/// every name. Only the sugar makes one (`registrar.drawRecords`).
@MainActor
public struct DrawRecording {
    let read: @MainActor (String, CanvasFile) -> DrawingRecord?
    let write: @MainActor (String, DrawingRecord?, inout Transaction) -> Void
    let names: @MainActor (CanvasFile) -> [String]
}

/// What keeps drawings: at most one plugin.
public enum DrawRecords {}

extension DrawRecords: KeyedExtensionPoint {
    public typealias Contribution = DrawRecording
    public static var owner: PluginID { .drawEngine }
    public static func uniqueKeys(of _: DrawRecording, for _: ShapeTarget) -> [AnyHashable] { [DrawPointKey(name: label)] }
    public static func summary(of _: DrawRecording, for _: ShapeTarget) -> String { label }
    static let label = "draw records"
}

extension PluginRegistrar {
    /// Keeps drawings for `canvas apply` and `canvas draw --drawing`: `read` a drawing by name from a file, `write` one (or
    /// nil, none) in a transaction, list the `names` a file has.
    public mutating func drawRecords(read: @escaping @MainActor (String, CanvasFile) -> DrawingRecord?,
                                     write: @escaping @MainActor (String, DrawingRecord?, inout Transaction) -> Void,
                                     names: @escaping @MainActor (CanvasFile) -> [String]) {
        contribute(DrawRecording(read: read, write: write, names: names), to: DrawRecords.self)
    }
}

extension Registry {
    /// What keeps drawings, if a plugin does.
    @MainActor var drawRecording: DrawRecording? { contributions(to: DrawRecords.self).first?.value }
}

extension BoardID {
    /// A board as a record writes it, `root` or its owner's id, read back.
    init?(recorded text: String) {
        if text == BoardID.root.description { self = .root; return }
        guard let uuid = UUID(uuidString: text) else { return nil }
        self = BoardID(owner: ShapeID(uuid))
    }
}
