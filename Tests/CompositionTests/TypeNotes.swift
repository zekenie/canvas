import Canvas
import CoreGraphics
import Mentions
import StickyNotes
import Titles
import Types

// Notes that are types, as the tests make them: a sticky note holding a schema (Types'), named by its
// title, saying in its text what the schema holds.

/// A type note: `schema`, its text `text`, titled `title` if given.
func typeNote(_ schema: String, text: MentionText = "", title: String? = nil, frame: CGRect = CGRect(x: 0, y: 0, width: 200, height: 200),
                         id: ShapeID = ShapeID()) -> AnyShapeRecord {
    var note = ShapeRecord(id: id, StickyNote(frame: frame, text: text))
    note[TypeSchemaProperty.self] = SchemaText(schema)
    if let title { note[TitleProperty.self] = title }
    return AnyShapeRecord(note)
}

extension CanvasEditor {
    /// Adds a type note (`typeNote`).
    @discardableResult
    func addTypeNote(_ schema: String, text: MentionText = "", title: String? = nil, frame: CGRect = CGRect(x: 0, y: 0, width: 200, height: 200),
                     id: ShapeID = ShapeID()) -> ShapeID {
        let record = typeNote(schema, text: text, title: title, frame: frame, id: id)
        transact { $0.insert(record) }
        return record.id
    }

    /// A shape's schema, anywhere in the file: a type note's.
    func schemaText(_ id: ShapeID) -> String? { shape(inFile: id)?[TypeSchemaProperty.self]?.text }
}
