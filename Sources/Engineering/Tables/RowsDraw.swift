import Canvas
import CanvasRPC
import Draw
import Foundation

// `canvas draw`'s words for a table's columns and an enum's values: each takes text, a row a line in its grammar
// (`columns: "id uuid pk\ncustomer_id uuid"`, `values: "pending\npaid"`), or the rows as JSON, and joins them onto what the
// shape holds by name (a column) or text (a value), so a statement names only what it changes, the rows it leaves out
// stay, and a script run again is `unchanged`. A column's type that names an enum of the file is bound to it. A key's `→`
// is kept as words until keys land.

/// What the writers say the text takes, which `canvas kinds` shows.
enum RowsDraw {
    static let columnLines = "lines (name type [null] [unique] [default …] [pk])"
    static let valueLines = "lines (a value each)"
    static let reason = "invalid_value"

    /// The columns a script wrote: its lines read, or its JSON items (an id given to each that has none), each type that
    /// names an enum bound to it.
    @MainActor
    static func columns(written value: JSONValue, _ context: DrawTextContext) throws(DrawError) -> JSONValue {
        let read: [Column]
        switch value {
        case .string(let text): read = ColumnGrammar.read(lines: text)
        case .array(let items): read = try items.map { item throws(DrawError) in try decoded(item, as: Column.self) }
        default: return value
        }
        let bound = read.map { column in
            var column = column
            if column.type.shape == nil, !column.type.words.isEmpty, let found = try? context.shape(called: column.type.words, admitting: {
                $0.kind == DatabaseEnum.kind ? nil : "which isn't an enum"
            }) {
                column.type.shape = found.id
            }
            return column
        }
        return (try? JSONValue(encoding: bound)) ?? value
    }

    /// The values a script wrote: its lines read, or its JSON items.
    @MainActor
    static func values(written value: JSONValue) throws(DrawError) -> JSONValue {
        switch value {
        case .string(let text): return (try? JSONValue(encoding: EnumGrammar.read(lines: text))) ?? value
        case .array(let items): return (try? JSONValue(encoding: try items.map { item throws(DrawError) in try decoded(item, as: EnumValue.self) })) ?? value
        default: return value
        }
    }

    /// `written` joined onto `held`, as `join` joins rows.
    static func merged<Row: Codable>(_ written: JSONValue, onto held: JSONValue?, as _: Row.Type, _ join: ([Row], [Row]) -> [Row]) -> JSONValue {
        guard let rows = try? written.decode([Row].self) else { return written }
        let kept = held.flatMap { try? $0.decode([Row].self) } ?? []
        return (try? JSONValue(encoding: join(rows, kept))) ?? written
    }

    /// A row written as JSON: an id given where it has none.
    private static func decoded<Row: Decodable>(_ item: JSONValue, as _: Row.Type) throws(DrawError) -> Row {
        var item = item
        if case .object(var members) = item, members["id"] == nil {
            members["id"] = .string(UUID().uuidString)
            item = .object(members)
        }
        do {
            return try item.decode(Row.self)
        } catch {
            throw DrawError("\(item.compactText) isn't a row it takes", reason: reason)
        }
    }
}

extension PluginRegistrar {
    /// The writers of a table's `columns:` and an enum's `values:`.
    mutating func rowsDraw() {
        drawValueWriter(for: "columns", describes: RowsDraw.columnLines, write: { value, context throws(DrawError) in
            try RowsDraw.columns(written: value, context)
        }, merge: { written, held in
            RowsDraw.merged(written, onto: held, as: Column.self, ColumnGrammar.merge)
        })
        drawValueWriter(for: "values", describes: RowsDraw.valueLines, write: { value, _ throws(DrawError) in
            try RowsDraw.values(written: value)
        }, merge: { written, held in
            RowsDraw.merged(written, onto: held, as: EnumValue.self, EnumGrammar.merge)
        })
    }
}
