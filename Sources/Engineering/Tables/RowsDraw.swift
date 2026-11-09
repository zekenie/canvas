import Canvas
import CanvasRPC
import Connections
import Draw
import Foundation

// `canvas draw`'s words for a table's columns and an enum's values: each takes text, a row a line in its grammar
// (`columns: "id uuid pk\ncustomer_id uuid"`, `values: "pending\npaid"`), or the rows as JSON, and joins them onto what the
// shape holds by name (a column) or text (a value), so a statement names only what it changes, the rows it leaves out
// stay, and a script run again is `unchanged`. A column's type that names an enum of the file is bound to it. A line's key,
// `→ customers.id`, is an edge the value implies (`implies`), drawn as `edge "orders".customer_id -> "customers".id channel:
// foreign-key` on the statement's line, so the column keeps none of its words; a line without one leaves a key alone.

/// What the writers say the text takes, which `canvas kinds` shows.
enum RowsDraw {
    static let columnLines = "lines (name type [null] [unique] [default …] [pk] [→ table.column])"
    static let valueLines = "lines (a value each)"
    static let reason = "invalid_value"
    /// What a name two shapes answer to is refused as (draw's own, for every name).
    static let ambiguousReason = "ambiguous_title"

    /// The columns a script wrote, each as the object a column is coded as: its lines read (every member a line says, a
    /// `default` it doesn't give written null, so a restated column loses it), or its JSON items as they were given (an
    /// id given to each that has none, only the members it names, a `type` written as a string its words), each type that
    /// names an enum bound to it. A name
    /// two enums answer to is refused, not left unbound without a word.
    @MainActor
    static func columns(written value: JSONValue, _ context: DrawTextContext) throws(DrawError) -> JSONValue {
        var items: [[String: JSONValue]]
        switch value {
        case .string(let text):
            items = ColumnGrammar.read(lines: text).map { column in
                var column = column
                // A key is its arrow, the edge the line implies: its words are no column's.
                if let key = ColumnGrammar.key(in: column.unread) { column.unread = key.rest }
                var members = (try? JSONValue(encoding: column))?.objectValue ?? [:]
                if members["default"] == nil { members["default"] = .null }
                return members
            }
        case .array(let given):
            items = try given.map { item throws(DrawError) in try decoded(item, as: Column.self).members }
        default: return value
        }
        // A type given as words alone is the file's enum of that name, when there is one.
        for index in items.indices {
            guard let type = items[index]["type"]?.objectValue, type["shape"] == nil, let words = type["words"]?.stringValue, !words.isEmpty,
                  let found = try enumNamed(words, context) else { continue }
            var bound = type
            bound["shape"] = (try? JSONValue(encoding: found)) ?? .null
            items[index]["type"] = .object(bound)
        }
        return .array(items.map(JSONValue.object))
    }

    /// The enum a column's type names, if it names one: a type of SQL's own and a name that isn't an enum's are none,
    /// but two enums of one name are refused, as any ambiguous name is.
    @MainActor
    private static func enumNamed(_ words: String, _ context: DrawTextContext) throws(DrawError) -> ShapeID? {
        do throws(DrawError) {
            return try context.shape(called: words, admitting: { $0.kind == DatabaseEnum.kind ? nil : "which isn't an enum" }).id
        } catch {
            guard error.reason == ambiguousReason else { return nil }
            throw error
        }
    }

    /// The keys a script's lines say (`→ customers.id`), each the edge it implies from its column, on the `foreign-key` channel: to
    /// the column named, or, for a table alone (`→ customers`), its primary key's (a table the script can't find is the edge's to
    /// refuse). JSON items say none.
    @MainActor
    static func keys(written value: JSONValue, _ context: DrawTextContext) throws(DrawError) -> [DrawImpliedEdge] {
        guard case .string(let text) = value else { return [] }
        var edges: [DrawImpliedEdge] = []
        for column in ColumnGrammar.read(lines: text) {
            guard let key = ColumnGrammar.key(in: column.unread) else { continue }
            var row = key.column
            var held: DatabaseTable?
            if row == nil {
                do throws(DrawError) {
                    let found = try context.shape(called: key.table, admitting: { $0.kind == DatabaseTable.kind ? nil : "which isn't a table" })
                    held = context.service(KitNames.self)?.editor.shape(inFile: found.id)?.typed(as: DatabaseTable.self).map(\.props)
                } catch {
                    // Two tables of one name are refused, as any ambiguous name is; any other is a table the file doesn't have.
                    if error.reason == ambiguousReason { throw error }
                }
                row = held.flatMap { ColumnLineGrammar.primaryKey(of: $0)?.name }
            }
            guard let row else {
                let why = held == nil ? "and the file has no such table yet to take its primary key from" : "and it has no primary key"
                throw DrawError("\(column.name)'s \(key.written) names no column of \(key.table), \(why)", reason: reason,
                                hint: "write \(ColumnGrammar.arrow) \(ColumnGrammar.written(table: key.table, column: "id"))")
            }
            edges.append(DrawImpliedEdge(fromRow: column.name, to: key.table, toRow: row, attributes: [ChannelProperty.key.rawValue: ForeignKey.id.rawValue], replacesType: ForeignKey.id.rawValue))
        }
        return edges
    }

    /// JSON columns as the writer reads them, before their schema checks them: a `type` written as a string (`"type": "uuid"`),
    /// as an endpoint's body is, is the words of a type, `{"words": "uuid"}`.
    static func reading(_ value: JSONValue) -> JSONValue {
        guard case .array(let items) = value else { return value }
        return .array(items.map { item in
            guard case .object(var members) = item, let words = members["type"]?.stringValue else { return item }
            members["type"] = .object(["words": .string(words)])
            return .object(members)
        })
    }

    /// The values a script wrote: its lines read, or its JSON items.
    @MainActor
    static func values(written value: JSONValue) throws(DrawError) -> JSONValue {
        switch value {
        case .string(let text): return (try? JSONValue(encoding: EnumGrammar.read(lines: text))) ?? value
        case .array(let items): return (try? JSONValue(encoding: try items.map { item throws(DrawError) in try decoded(item, as: EnumValue.self).row })) ?? value
        default: return value
        }
    }

    /// The columns `written` says joined onto `held`: each item is read over the held column of its name, so a member it
    /// leaves out stays (a null puts one back to its default), then joined as the grammar joins (`ColumnGrammar.merge`: a new
    /// one after the column written before it, else last), except that an `onDelete` or `onUpdate` it gives is the column's. A
    /// new column whose id another holds, or another written one has, is given one of its own.
    static func mergedColumns(_ written: JSONValue, onto held: JSONValue?) -> JSONValue {
        guard case .array(let items) = written else { return written }
        var merged = held.flatMap { try? $0.decode([Column].self) } ?? []
        var previous: String?
        for case .object(let given) in items {
            let old = merged.first { $0.name == given["name"]?.stringValue ?? "" }
            var members = old.flatMap { try? JSONValue(encoding: $0).objectValue } ?? [:]
            for (key, member) in given where key != "id" || member != .null { members[key] = member == .null ? nil : member }
            guard var column = try? JSONValue.object(members).decode(Column.self) else { continue }
            if old == nil, merged.contains(where: { $0.id == column.id }) { column.id = PartID() }
            merged = ColumnGrammar.merge([column], onto: merged, after: previous)
            previous = column.name
            guard let at = merged.firstIndex(where: { $0.name == column.name }) else { continue }
            if let onDelete = given["onDelete"] { merged[at].onDelete = onDelete.stringValue }
            if let onUpdate = given["onUpdate"] { merged[at].onUpdate = onUpdate.stringValue }
        }
        return (try? JSONValue(encoding: merged)) ?? written
    }

    /// The values `written` says joined onto `held` by text, a new value whose id another has given one of its own.
    static func mergedValues(_ written: JSONValue, onto held: JSONValue?) -> JSONValue {
        guard let values = try? written.decode([EnumValue].self) else { return written }
        var merged = held.flatMap { try? $0.decode([EnumValue].self) } ?? []
        var previous: String?
        for var value in values {
            if !merged.contains(where: { $0.text == value.text }), merged.contains(where: { $0.id == value.id }) { value.id = PartID() }
            merged = EnumGrammar.merge([value], onto: merged, after: previous)
            previous = value.text
        }
        return (try? JSONValue(encoding: merged)) ?? written
    }

    /// A row written as JSON: an id given where it has none, and the members as it gave them. It must read as a row.
    private static func decoded<Row: Decodable>(_ item: JSONValue, as _: Row.Type) throws(DrawError) -> (members: [String: JSONValue], row: Row) {
        var item = item
        if case .object(var members) = item, members["id"] == nil {
            members["id"] = .string(UUID().uuidString)
            item = .object(members)
        }
        do {
            return (item.objectValue ?? [:], try item.decode(Row.self))
        } catch {
            throw DrawError("\(item.compactText) isn't a row it takes", reason: reason)
        }
    }
}

extension PluginRegistrar {
    /// The writers of a table's `columns:` and an enum's `values:`.
    mutating func rowsDraw() {
        drawValueWriter(for: "columns", describes: RowsDraw.columnLines, reading: RowsDraw.reading, write: { value, context throws(DrawError) in
            try RowsDraw.columns(written: value, context)
        }, implies: { value, context throws(DrawError) in
            try RowsDraw.keys(written: value, context)
        }, merge: { written, held in
            RowsDraw.mergedColumns(written, onto: held)
        })
        drawValueWriter(for: "values", describes: RowsDraw.valueLines, write: { value, _ throws(DrawError) in
            try RowsDraw.values(written: value)
        }, merge: { written, held in
            RowsDraw.mergedValues(written, onto: held)
        })
    }
}
