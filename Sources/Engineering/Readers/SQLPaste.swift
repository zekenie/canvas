import Canvas
import Clipboard
import Draw
import Foundation
import Selection

// ⌘V of SQL: what the reader read (`SQLReader`), as the draw program Draw puts down (`DrawPut`, decided 16). Each table a `table`
// statement by its title, within its schema's database (`billing.payments` is the payments in the database billing, else any
// payments: a paste makes no database), its columns as JSON with every member SQL says, so a type of several words, a default and
// what a key does on delete stay whole; each enum an `enum-type` statement, its values by text; in paste order, four to a row.
// Draw finds each by its title, nearest first and file-wide, and joins the columns onto what a found table holds by name (the
// columns' writer, `ColumnGrammar.merge`): a column keeps its id, so the keys bound to it stay, a new one goes after the column
// pasted before it, and one the paste leaves out stays. Each key is an edge the table's statement implies, from its column to the
// row it names (a table named alone: its primary key's, the pasted table's, else the one the file has), on the kit's key channel:
// drawn if absent, re-aimed where the column's key went elsewhere; a column pasted without one keeps its key. A key whose table
// is found nowhere, or whose row the table hasn't, is left out, and the column is plain.

/// The SQL paste reader.
public enum SQLPaste {
    /// Its name, and so its step's: "Paste SQL".
    static let name = "SQL"
    /// How many shapes a row of what lands holds.
    static let shapesARow = 4
    /// A file of SQL.
    static let fileExtension = "sql"

    /// The edges a key is drawn as: the maker's attributes (its channel), and the type of edge a column has one of.
    struct KeyChannel {
        var attributes: [String: String]
        var type: String
    }

    /// Whether the pasteboard may hold SQL, cheaply: a `.sql` file, or text with `CREATE TABLE` or `AS ENUM` in its first 64 KB.
    static func sniffs(_ content: PasteContent) -> Bool {
        if content.files.contains(where: { $0.fileExtension == fileExtension }) { return true }
        return content.text.map(SQLReader.sniffs) ?? false
    }

    /// The SQL on the pasteboard: its `.sql` files' text, else its text.
    static func text(of content: PasteContent) -> String? {
        let files = content.files.filter { $0.fileExtension == fileExtension }.compactMap(\.text)
        if !files.isEmpty { return files.joined(separator: "\n;\n") }
        return content.text
    }

    /// What ⌘V puts down of the pasteboard's SQL, beside the selection: nil when no table and no enum reads.
    @MainActor
    static func read(_ content: PasteContent, in editor: CanvasEditor, keys: KeyChannel) -> DrawPut? {
        text(of: content).flatMap { program(of: $0, at: .beside(editor.selectedShapeIDs), in: editor, keys: keys) }
    }

    /// What a paste of `text` puts down at `site`: nil when no table and no enum reads.
    @MainActor
    static func program(of text: String, at site: PutSite, in editor: CanvasEditor, keys: KeyChannel) -> DrawPut? {
        let schema = SQLReader.read(text)
        return schema.isEmpty ? nil : put(schema, at: site, in: editor, keys: keys)
    }

    /// The program that puts `schema` down at `site`: its tables and enums in the order they were made, four to a row, each table's
    /// keys the edges it implies.
    @MainActor
    static func put(_ schema: SQLSchema, at site: PutSite, in editor: CanvasEditor, keys: KeyChannel) -> DrawPut {
        var shapes: [DrawPut.Shape] = []
        for item in schema.order {
            switch item {
            case .table(let index): shapes.append(table(schema.tables[index], of: schema, at: site, in: editor, keys: keys))
            case .enumType(let index): shapes.append(enumType(schema.enums[index]))
            }
        }
        let rows = stride(from: 0, to: shapes.count, by: shapesARow).map { Array(shapes[$0..<min($0 + shapesARow, shapes.count)]) }
        return DrawPut(rows: rows)
    }

    // MARK: Statements

    /// A table's statement: its title, its schema's database, its columns as JSON, its keys as edges.
    @MainActor
    private static func table(_ table: SQLTable, of schema: SQLSchema, at site: PutSite, in editor: CanvasEditor, keys: KeyChannel) -> DrawPut.Shape {
        let columns: [Any] = table.columns.map { column in
            var item: [String: Any] = [
                "name": column.name,
                "type": ["words": typeWords(column.type.words, in: schema)],
                "nullable": column.nullable,
                "unique": column.unique,
                "primaryKey": column.primaryKey,
                // No default said: none, as a line that says none.
                "default": column.default ?? NSNull(),
            ]
            if let onDelete = column.onDelete { item["onDelete"] = onDelete }
            if let onUpdate = column.onUpdate { item["onUpdate"] = onUpdate }
            return item
        }
        var edges: [DrawPut.Edge] = []
        for key in table.keys {
            let far = pasted(key.table, in: schema)
            let farName = far?.name ?? key.table
            // A key that names no column names its table's primary key's: the pasted table's, else the one the file has.
            var row = key.targetColumn ?? far.flatMap { key.target(primaryKey: $0.primaryKey) }
            if row == nil, let found = shape(DatabaseTable.kind, farName).found(at: site, in: editor),
               let held = editor.shape(inFile: found)?.typed(as: DatabaseTable.self)?.props {
                row = key.target(primaryKey: held.columns.filter(\.primaryKey).map(\.name))
            }
            guard let row else { continue }
            edges.append(DrawPut.Edge(fromRow: key.column, toKind: DatabaseTable.kind.rawValue, toTitle: farName.name, toWithin: within(farName),
                                      toRow: row, attributes: keys.attributes, replacesType: keys.type))
        }
        var shape = shape(DatabaseTable.kind, table.name)
        shape.json = [(key: "columns", text: json(columns))]
        shape.edges = edges
        return shape
    }

    /// An enum's statement: its title, its schema's database, its values as JSON (each as written, spaces and all).
    private static func enumType(_ type: SQLEnum) -> DrawPut.Shape {
        var shape = shape(DatabaseEnum.kind, type.name)
        shape.json = [(key: "values", text: json(type.values.map { ["text": $0] }))]
        return shape
    }

    /// A shape of `kind` named as SQL names it: its title, within the database its schema names.
    private static func shape(_ kind: ShapeKind, _ name: SQLName) -> DrawPut.Shape {
        DrawPut.Shape(kind: kind.rawValue, title: name.name, within: within(name))
    }

    private static func within(_ name: SQLName) -> [String] { name.schema.map { [$0] } ?? [] }

    /// The table of the paste a key names: of its name and schema, else, for a name with no schema, the one table of the paste of
    /// that name.
    private static func pasted(_ name: SQLName, in schema: SQLSchema) -> SQLTable? {
        if let table = schema.tables.first(where: { $0.name == name }) { return table }
        guard name.schema == nil else { return nil }
        let named = schema.tables.filter { $0.name.name == name.name }
        return named.count == 1 ? named[0] : nil
    }

    /// A column's type words as a column holds them: an enum the paste makes by its name (its title), so the column's type finds
    /// it, and `public.` dropped.
    static func typeWords(_ words: String, in schema: SQLSchema) -> String {
        if let type = schema.enums.first(where: { $0.name.description == words || ($0.name.schema == nil && "\(SQLReader.defaultSchema).\($0.name.name)" == words) }) {
            return type.name.name
        }
        let schemaPrefix = SQLReader.defaultSchema + "."
        return words.hasPrefix(schemaPrefix) ? String(words.dropFirst(schemaPrefix.count)) : words
    }

    /// A value as JSON text.
    private static func json(_ value: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }
}
