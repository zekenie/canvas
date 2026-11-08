import Canvas
import Clipboard
import Draw
import Foundation

// ⌘V of SQL: what the reader read (`SQLReader`), as the draw program Draw puts down (`DrawPut`, decided 16). Each table a `table`
// statement by its title, within its schema's database (`billing.payments` is the payments in the database billing, else any
// payments: a paste makes no database), its columns as JSON with every member SQL says, so a type of several words, a default and
// what a key does on delete stay whole; each enum an `enum-type` statement, its values by text; in paste order, four to a row.
// Draw finds each by its title, nearest first and file-wide, and joins the columns onto what a found table holds by name (the
// columns' writer, `ColumnGrammar.merge`): a column keeps its id, so the keys bound to it stay, a new one goes after the column
// pasted before it, and one the paste leaves out stays. Each key is an edge the table's statement implies, from its column to the
// row it names (a table named alone: its primary key's, the pasted table's, else the one the put finds, asked when it puts, so the
// reading holds only the text and is the same wherever it lands), on the kit's key channel: drawn if absent, re-aimed where the
// column's key went elsewhere; a column pasted without one keeps its key. A key whose table is found nowhere, or whose row the
// table hasn't, is left out, and the column is plain (a key it had stays). A column pasted with a key has the key's actions as SQL
// says them, none included.

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

    /// What ⌘V puts down of the pasteboard's SQL: nil when no table and no enum reads.
    static func read(_ content: PasteContent, keys: KeyChannel) -> DrawPut? {
        text(of: content).flatMap { program(of: $0, keys: keys) }
    }

    /// What a paste of `text` puts down: nil when no table and no enum reads.
    static func program(of text: String, keys: KeyChannel) -> DrawPut? {
        let schema = SQLReader.read(text)
        return schema.isEmpty ? nil : put(schema, keys: keys)
    }

    /// The program that puts `schema` down: its tables and enums in the order they were made, four to a row, each table's keys the
    /// edges it implies.
    static func put(_ schema: SQLSchema, keys: KeyChannel) -> DrawPut {
        var shapes: [DrawPut.Shape] = []
        for item in schema.order {
            switch item {
            case .table(let index): shapes.append(table(schema.tables[index], of: schema, keys: keys))
            case .enumType(let index): shapes.append(enumType(schema.enums[index]))
            }
        }
        let rows = stride(from: 0, to: shapes.count, by: shapesARow).map { Array(shapes[$0..<min($0 + shapesARow, shapes.count)]) }
        return DrawPut(rows: rows)
    }

    // MARK: Statements

    /// A table's statement: its title, its schema's database, its columns as JSON, its keys as edges.
    private static func table(_ table: SQLTable, of schema: SQLSchema, keys: KeyChannel) -> DrawPut.Shape {
        let keyed = Set(table.keys.map(\.column))
        let columns: [Any] = table.columns.map { column in
            var item: [String: Any] = [
                "name": column.name,
                "type": ["words": typeWords(column.type.words, in: schema, from: table.name.schema)],
                "nullable": column.nullable,
                "unique": column.unique,
                "primaryKey": column.primaryKey,
                // No default said: none, as a line that says none.
                "default": column.default ?? NSNull(),
            ]
            // A key's actions are as SQL says them, none included (a pasted-again key that now says none has none); a column pasted
            // without a key keeps what it had.
            if keyed.contains(column.name) {
                item["onDelete"] = column.onDelete ?? NSNull()
                item["onUpdate"] = column.onUpdate ?? NSNull()
            }
            return item
        }
        var edges: [DrawPut.Edge] = []
        for key in table.keys {
            let far = pasted(key.table, in: schema)
            let farName = far?.name ?? key.table
            // A key that names no column names its table's primary key's: the pasted table's, else the one the put finds in the file.
            let row = key.targetColumn ?? far.flatMap { key.target(primaryKey: $0.primaryKey) }
            let ofFile = row == nil ? primaryKeyOfFile(for: key) : nil
            edges.append(DrawPut.Edge(fromRow: key.column, toKind: DatabaseTable.kind.rawValue, toTitle: farName.name, toWithin: within(farName),
                                      toRow: row, attributes: keys.attributes, replacesType: keys.type, toRowOfShape: ofFile))
        }
        var shape = shape(DatabaseTable.kind, table.name)
        shape.json = [(key: "columns", text: json(columns))]
        shape.edges = edges
        return shape
    }

    /// A key that names no column, asked of the table the put finds in the file: the column of its primary key the key's place says.
    private static func primaryKeyOfFile(for key: SQLKey) -> (@MainActor @Sendable (ShapeID, CanvasEditor) -> String?) {
        { @MainActor id, editor in
            guard let held = editor.shape(inFile: id)?.typed(as: DatabaseTable.self)?.props else { return nil }
            return key.target(primaryKey: held.columns.filter(\.primaryKey).map(\.name))
        }
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
    /// it, and `public.` dropped. An enum that shares its title with another shape of the paste is named by its schema too
    /// (`billing.status`), which the put calls it by; a name with no schema that more than one enum answers to is the one in the
    /// schema of the table that writes it (`home`), else the one with none.
    static func typeWords(_ words: String, in schema: SQLSchema, from home: String? = nil) -> String {
        func isNamed(_ type: SQLEnum) -> Bool {
            type.name.description == words || (type.name.schema == nil && "\(SQLReader.defaultSchema).\(type.name.name)" == words)
        }
        var named = schema.enums.filter(isNamed)
        if named.isEmpty, !words.contains(".") {
            // A bare name that only schemas' enums answer to: the table's own schema's, when it has one.
            named = schema.enums.filter { $0.name.name == words && $0.name.schema != nil && $0.name.schema == home }
        }
        if let type = named.first {
            let sharing = schema.enums.filter { $0.name.name == type.name.name }.count + schema.tables.filter { $0.name.name == type.name.name }.count
            return sharing > 1 ? type.name.description : type.name.name
        }
        let schemaPrefix = SQLReader.defaultSchema + "."
        return words.hasPrefix(schemaPrefix) ? String(words.dropFirst(schemaPrefix.count)) : words
    }

    /// A value as JSON text.
    private static func json(_ value: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }
}
