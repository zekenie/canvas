import Canvas
import CanvasRPC
import CoreGraphics
import Foundation

// The engineering kit's kinds as they're kept: a table, an enum and a database. Each is complete at version 0:
// every member a later landing reads is here now, so the rows those landings write and the keys they draw change
// no encoding. A table and an enum store their width (the frame's) and lay their height out from their rows, so a
// fold, later, is a layout input and writes nothing; a database is a region, as a frame is.

/// A database table: its columns, in order. Its name is Titles' (`title`). Only its frame's width is its own: its
/// height is laid out from its rows (`TableDefinition`, a `LaidOutBox`), and kept in step where a script makes one.
public struct DatabaseTable: BoxShapeProps {
    public static let kind: ShapeKind = "table"
    public static let properties = Properties<DatabaseTable>(title: "Table") {
        Property("frame", \.frame).required()
        Property("columns", \.columns).description("Its columns, in order.")
    }
    public var frame: CGRect
    public var columns: [Column]

    public init(frame: CGRect = .zero, columns: [Column] = []) {
        self.frame = frame
        self.columns = columns
    }

    public init() { self.init(frame: .zero) }

    /// What a new table holds: one column, `id uuid pk`.
    public static func starter() -> DatabaseTable {
        DatabaseTable(columns: [Column(name: "id", type: TypeRef("uuid"), primaryKey: true)])
    }
}

/// One column of a table: a row, with an id of the table's own that a copy keeps.
public struct Column: SchemaDefined, Hashable, Sendable {
    public static let properties = Properties<Column>(definition: "column", readsAs: "name") {
        Property("id", \.id).required()
        Property("name", \.name).description("What it's called.")
        Property("type", \.type).description("Its type, as written; an enum of the file's once its words name one.")
        Property("nullable", \.nullable).description("It may hold null (`null`, a `?` after its type).")
        Property("unique", \.unique).description("No two rows hold one value (`unique`).")
        Property("primaryKey", \.primaryKey).description("Part of the table's primary key (`pk`).")
        Property("default", \.default).description("What a row holds when none is given (`default now()`), as written.")
        Property("onDelete", \.onDelete).description("What a key from it does when the row it names is deleted, as written (cascade, restrict, set null).")
        Property("onUpdate", \.onUpdate).description("What a key from it does when the row it names changes its key, as written.")
        Property("unread", \.unread).description("Words its line held that no part of a column reads, kept as written.")
    }
    public var id: PartID
    public var name: String
    public var type: TypeRef
    public var nullable: Bool
    public var unique: Bool
    public var primaryKey: Bool
    public var `default`: String?
    public var onDelete: String?
    public var onUpdate: String?
    public var unread: String

    public init(id: PartID = PartID(), name: String, type: TypeRef, nullable: Bool = false, unique: Bool = false, primaryKey: Bool = false,
                default: String? = nil, onDelete: String? = nil, onUpdate: String? = nil, unread: String = "") {
        self.id = id
        self.name = name
        self.type = type
        self.nullable = nullable
        self.unique = unique
        self.primaryKey = primaryKey
        self.default = `default`
        self.onDelete = onDelete
        self.onUpdate = onUpdate
        self.unread = unread
    }

    public init() { self.init(name: "", type: TypeRef("")) }
}

/// Its type's words may name an enum, which a copy renames.
extension Column: ShapeNaming {}

/// A type as its words say it, and the shape those words name once one matches (a column's enum): a name, not a
/// binding, so it may be on any board, outlives its shape (its words stay) and a copy renames it, as a reference's
/// target is. Coded as `{"words": "order_status", "shape": "<uuid>"}`, the shape left out while it names none.
public struct TypeRef: Codable, Hashable, Sendable {
    /// As written: "uuid", "char(3)", "order_status".
    public var words: String
    /// The shape its words name (an enum), nil for a type of SQL's own or one nothing matches.
    public var shape: ShapeID?

    public init(_ words: String, shape: ShapeID? = nil) {
        self.words = words
        self.shape = shape
    }
}

extension TypeRef: SchemaDescribed {
    public static func schema(in definitions: inout SchemaDefinitions) -> JSONObject {
        definitions.reference("type-ref", of: Self.self) { _ in
            ["type": "object",
             "properties": ["words": ["type": "string"], "shape": ["type": "string", "format": "uuid"]],
             "required": ["words"],
             "additionalProperties": false,
             KindSchema.readsAsKeyword: "words",
             "description": "A type as written, and the shape its words name (an enum), if one matches."]
        }
    }
}

extension TypeRef: ShapeNaming {
    public func forEachNamedShape(_ body: (ShapeID) -> Void) { shape.map(body) }

    public func renamingShapes(_ rename: (ShapeID) -> ShapeID?) -> TypeRef {
        TypeRef(words, shape: shape.map { rename($0) ?? $0 })
    }
}

/// An enum type: its values, in order. Its name is Titles' (`title`); its width is its own and its height its rows'.
public struct DatabaseEnum: BoxShapeProps {
    public static let kind: ShapeKind = "enum-type"
    public static let properties = Properties<DatabaseEnum>(title: "Enum") {
        Property("frame", \.frame).required()
        Property("values", \.values).description("Its values, in order.")
    }
    public var frame: CGRect
    public var values: [EnumValue]

    public init(frame: CGRect = .zero, values: [EnumValue] = []) {
        self.frame = frame
        self.values = values
    }

    public init() { self.init(frame: .zero) }
}

/// One value of an enum: a row, with an id of the enum's own, so a rename keeps it.
public struct EnumValue: SchemaDefined, Hashable, Sendable {
    public static let properties = Properties<EnumValue>(definition: "enum-value", readsAs: "text") {
        Property("id", \.id).required()
        Property("text", \.text).description("The value.")
    }
    public var id: PartID
    public var text: String

    public init(id: PartID = PartID(), text: String) {
        self.id = id
        self.text = text
    }

    public init() { self.init(text: "") }
}

/// A database: a region of its board that holds tables and enums, as a frame does (the core's containment). Its
/// props are only its frame; its name is Titles'.
public struct Database: BoxShapeProps {
    public static let kind: ShapeKind = "database"
    public static let properties = Properties<Database>(title: "Database") {
        Property("frame", \.frame).required()
    }
    public var frame: CGRect

    public init(frame: CGRect) { self.frame = frame }
    public init() { self.init(frame: .zero) }
}
