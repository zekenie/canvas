import Canvas
import CoreGraphics
import Draw
import Foundation

// What a query reads of the file's drawings: taken in the turn a query takes up the file in O(1) (the file is a value, and each
// kind's schema a table the registry keeps), and read off the main actor after, one drawing at a time: what it made that the
// file holds, what is gone, which of its shapes holds a row's shape, and how a shape now differs from what it last wrote.

/// The file's drawings as a query takes them up: the file (to tell a shape the file holds from one that is gone, and every
/// drawing by name) and each kind's schema (to read a shape's properties as a drawing writes them, off the main actor, whatever
/// kind the shape is now).
public struct DrawingFacts: Sendable {
    let file: CanvasFile
    let schemas: [String: KindSchema]

    @MainActor
    init(editor: CanvasEditor) {
        file = editor.withoutObservingDocument { editor.file }
        let registry = editor.registry
        schemas = registry.memo(SchemaTable()) {
            Dictionary(registry.kinds.map { ($0.rawValue, KindSchema(registry.schema(for: $0) ?? JSONSchema([:]))) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// The key a registry keeps the table of every kind's schema by.
    private struct SchemaTable: Hashable {}

    /// The drawing called `name`, as the file holds its record.
    func drawing(_ name: String) -> DrawingRecord? { file[DrawingsProperty.self].drawings[name] }

    /// The shapes `name` made that the file holds: O(the drawing), off the main actor.
    func held(by name: String) -> Set<ShapeID> {
        Set((drawing(name)?.shapes ?? [:]).keys.compactMap { text in
            UUID(uuidString: text).map(ShapeID.init).flatMap { file.record($0) == nil ? nil : $0 }
        })
    }

    /// What `name` made that the file no longer holds: each id and key, by key.
    func gone(from name: String) -> [(id: String, key: String)] {
        (drawing(name)?.shapes ?? [:]).compactMap { text, shape in
            guard let uuid = UUID(uuidString: text), file.record(ShapeID(uuid)) == nil else { return nil }
            return (text, shape.key)
        }.sorted { ($0.key, $0.id) < ($1.key, $1.id) }
    }

    /// The key of the drawing's shape that holds `record` (its frame, else the shape whose board it is on), when `name` made that one.
    func holder(of record: AnyShapeRecord, on board: BoardID, in drawing: DrawingRecord) -> String? {
        if let container = record.container, let shape = drawing.shapes[container.description] { return shape.key }
        if let owner = board.owner, let shape = drawing.shapes[owner.description] { return shape.key }
        return nil
    }

    /// How a shape differs from what `drawing` last wrote of it: none for one it didn't make, or one as it was written.
    func changes(of record: AnyShapeRecord, on board: BoardID, in drawing: DrawingRecord) -> [String] {
        guard let wrote = drawing.shapes[record.id.description]?.wrote,
              let now = Self.state(of: record, on: board, schema: schemas[record.kind.rawValue]) else { return [] }
        return now.changes(from: wrote)
    }

    /// A shape as a drawing writes it (`DrawnState.of`), read with its kind's schema alone, off the main actor.
    static func state(of record: AnyShapeRecord, on board: BoardID, schema: KindSchema?) -> DrawnState? {
        guard !record.isOpaque else { return nil }
        var props = record.propertiesJSON ?? [:]
        if let schema { for key in props.keys where schema.holdsPlace(key) { props[key] = nil } }
        let box = record.box.map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] }
        return DrawnState(kind: record.kind.rawValue, props: props, board: board.description, container: record.container?.description, box: box)
    }
}
