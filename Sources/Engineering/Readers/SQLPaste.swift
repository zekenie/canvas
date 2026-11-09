import Adornments
import Canvas
import Clipboard
import Draw
import Foundation

// ⌘V of SQL: what the reader read (`SQLReader`), as the draw program Draw puts down (`DrawPut`, decided 16). Each table a `table`
// statement by its title, within its schema's database (`billing.payments` is the payments in the database billing, else any
// payments: a paste makes no database), its columns as JSON with every member SQL says, so a type of several words, a default and
// what a key does on delete stay whole, made as wide as its longest line needs (`TableDefinition.wholeWidth`, capped), so a dump's
// `timestamp with time zone` reads whole; each enum an `enum-type` statement, its values by text. Laid out by its keys, so they
// join neighbors and run level: the enums on rows of their own, first, then the tables in a walk from the one most keys name, each
// after the table it keys to most (`laidOut`), four to a row.
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
    @MainActor
    static func read(_ content: PasteContent, keys: KeyChannel, fileEnums: Set<String> = []) -> DrawPut? {
        text(of: content).flatMap { program(of: $0, keys: keys, fileEnums: fileEnums) }
    }

    /// What a paste of `text` puts down: nil when no table and no enum reads. `fileEnums`: the names of the enums the file has, which
    /// a column of the paste may name too (drawn as a pill, so measured as one).
    @MainActor
    static func program(of text: String, keys: KeyChannel, fileEnums: Set<String> = []) -> DrawPut? {
        let schema = SQLReader.read(text)
        return schema.isEmpty ? nil : put(schema, keys: keys, fileEnums: fileEnums)
    }

    /// The program that puts `schema` down: its enums on rows of their own, then its tables as their keys lay them out (`laidOut`),
    /// four to a row, each table's keys the edges it implies.
    @MainActor
    static func put(_ schema: SQLSchema, keys: KeyChannel, fileEnums: Set<String> = []) -> DrawPut {
        func rows(_ shapes: [DrawPut.Shape]) -> [[DrawPut.Shape]] {
            stride(from: 0, to: shapes.count, by: shapesARow).map { Array(shapes[$0..<min($0 + shapesARow, shapes.count)]) }
        }
        let enums = schema.order.compactMap { item -> DrawPut.Shape? in
            if case .enumType(let index) = item { enumType(schema.enums[index]) } else { nil }
        }
        let made = schema.tables.indices.map { table(schema.tables[$0], of: schema, keys: keys, fileEnums: fileEnums) }
        let grid = ReaderLayout.grid(laidOut(schema), links: links(schema), columns: shapesARow)
        return DrawPut(grid: rows(enums).map { $0.map(Optional.some) } + grid.map { $0.map { $0.map { made[$0] } } })
    }

    /// The order a schema's tables are put down in, by their keys: from the table most keys of the paste name (the first made, of
    /// those named alike), a walk that puts each table's neighbors after it, the one with most keys between them first (a table
    /// that keys to it, or that it keys to), so each lands after the table it keys to most and most keys join tables a row apart
    /// or less; then from the most named of those left, and so on. A pg_dump's alphabet, or the order a schema was made in, is
    /// never what its keys say. Indexes into `schema.tables`.
    static func laidOut(_ schema: SQLSchema) -> [Int] {
        ReaderLayout.walk(tableOrder(schema), links: links(schema))
    }

    /// The schema's tables as read, by index.
    private static func tableOrder(_ schema: SQLSchema) -> [Int] {
        schema.order.compactMap { item -> Int? in if case .table(let index) = item { index } else { nil } }
    }

    /// One link a key, from the table it's in to the pasted table it names.
    private static func links(_ schema: SQLSchema) -> [(from: Int, to: Int)] {
        var links: [(from: Int, to: Int)] = []
        for from in tableOrder(schema) {
            for key in schema.tables[from].keys {
                guard let far = pasted(key.table, in: schema), let to = schema.tables.firstIndex(where: { $0.name == far.name }) else { continue }
                links.append((from, to))
            }
        }
        return links
    }

    // MARK: Statements

    /// A table's statement: its title, its schema's database, its columns as JSON, its keys as edges.
    @MainActor
    private static func table(_ table: SQLTable, of schema: SQLSchema, keys: KeyChannel, fileEnums: Set<String>) -> DrawPut.Shape {
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
        // As wide as its columns read whole (a pg_dump's `character varying(255)`), as a commit widens a table (Tables'), an enum
        // the paste makes or the file has measured as the pill it is drawn as, not as its words; a table the file has is widened to
        // it where it is narrower, in the paste's step, and never narrowed, so a width a person set stays unless the new lines need more.
        shape.size = DrawPut.Dimensions(width: TableDefinition.wholeWidth(of: table.columns.map { column in
            let words = typeWords(column.type.words, in: schema, from: table.name.schema)
            let named = pastedEnum(named: column.type.words, in: schema, from: table.name.schema)?.name.name ?? (fileEnums.contains(words) ? words : nil)
            let pill = named.map { AdornmentLabel($0).tinted(TableStyle.enumPill) }
            return TableDefinition.WholeRow(name: column.name, type: words, pill: pill, nullable: column.nullable)
        }), widens: true)
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
        if let type = pastedEnum(named: words, in: schema, from: home) {
            let sharing = schema.enums.filter { $0.name.name == type.name.name }.count + schema.tables.filter { $0.name.name == type.name.name }.count
            return sharing > 1 ? type.name.description : type.name.name
        }
        let schemaPrefix = SQLReader.defaultSchema + "."
        return words.hasPrefix(schemaPrefix) ? String(words.dropFirst(schemaPrefix.count)) : words
    }

    /// The enum of the paste a column's type words name, if one: by its name and schema, or by a bare name, which more than one
    /// answers to, the one in the schema of the table that writes it (`home`).
    static func pastedEnum(named words: String, in schema: SQLSchema, from home: String?) -> SQLEnum? {
        func isNamed(_ type: SQLEnum) -> Bool {
            type.name.description == words || (type.name.schema == nil && "\(SQLReader.defaultSchema).\(type.name.name)" == words)
        }
        var named = schema.enums.filter(isNamed)
        if named.isEmpty, !words.contains(".") {
            // A bare name that only schemas' enums answer to: the table's own schema's, when it has one.
            named = schema.enums.filter { $0.name.name == words && $0.name.schema != nil && $0.name.schema == home }
        }
        return named.first
    }

    /// A value as JSON text.
    private static func json(_ value: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }
}

/// How a reader orders what it puts down so that what refers to what lands together (`DrawPut` rows, four to a row): a table
/// after the one it keys to most, a type after the one that refers to it most.
enum ReaderLayout {
    /// `items` (in the order they were read) ordered by `links` (one from an item to the item it refers to, as often as it does;
    /// one to itself counts for nothing): from the item most links name (the first read of a tie), a walk that puts each item's
    /// neighbors after it, the one with most links between them first (either way), then the order read; then from the most named
    /// of those left, and so on. Every item once.
    static func walk(_ items: [Int], links: [(from: Int, to: Int)]) -> [Int] {
        var weight: [Int: [Int: Int]] = [:], named: [Int: Int] = [:]
        let known = Set(items)
        for link in links where link.from != link.to && known.contains(link.from) && known.contains(link.to) {
            named[link.to, default: 0] += 1
            weight[link.from, default: [:]][link.to, default: 0] += 1
            weight[link.to, default: [:]][link.from, default: 0] += 1
        }
        let place = Dictionary(items.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var laid: [Int] = [], seen: Set<Int> = []
        while laid.count < place.count {
            // The most named of those left, the first read of a tie.
            guard let start = items.filter({ !seen.contains($0) }).max(by: { (named[$0] ?? 0, place[$1]!) < (named[$1] ?? 0, place[$0]!) }) else { break }
            var queue = [start]
            seen.insert(start)
            while !queue.isEmpty {
                let item = queue.removeFirst()
                laid.append(item)
                let next = (weight[item] ?? [:]).filter { !seen.contains($0.key) }
                    .sorted { ($0.value, place[$1.key]!) > ($1.value, place[$0.key]!) }.map(\.key)
                for neighbor in next {
                    seen.insert(neighbor)
                    queue.append(neighbor)
                }
            }
        }
        return laid
    }

    /// `order` (a walk's) put in a grid `columns` wide, each item in turn in the cell that keeps its links (`links`, as `walk`
    /// reads them) shortest and clear: a link between two cells side by side, one above the other or corner to corner costs
    /// nothing; a longer one costs by how far it reaches and, twice over, by each card its straight run passes under, as does an
    /// item put on the run of a link laid already; an item with links still to lay is put where the most of its neighbors can
    /// still go round it. The cheapest cell wins, the higher row and then the left column of a tie, so a table's most-keyed
    /// neighbors land beside it, or right above or below it, and fewer keys pass under cards (UX walk 3 paste-1). Rows top to
    /// bottom, each its cells left to right, nil an empty one; no row empty, and no column empty all the way down.
    static func grid(_ order: [Int], links: [(from: Int, to: Int)], columns: Int) -> [[Int?]] {
        guard columns > 0, !order.isEmpty else { return [] }
        var weight: [Int: [Int: Int]] = [:]
        let known = Set(order)
        for link in links where link.from != link.to && known.contains(link.from) && known.contains(link.to) {
            weight[link.from, default: [:]][link.to, default: 0] += 1
            weight[link.to, default: [:]][link.from, default: 0] += 1
        }
        struct Cell: Hashable { var row: Int, column: Int }
        var at: [Int: Cell] = [:], taken: [Cell: Int] = [:]
        // The cells a straight run between two cells' middles passes over, the two aside.
        func under(_ a: Cell, _ b: Cell) -> Set<Cell> {
            var cells: Set<Cell> = []
            let steps = 8 * max(abs(a.row - b.row), abs(a.column - b.column), 1)
            for step in 1..<steps {
                let t = Double(step) / Double(steps)
                let x = Double(a.column) + 0.5 + Double(b.column - a.column) * t, y = Double(a.row) + 0.5 + Double(b.row - a.row) * t
                // A run along the line between two cells, or through the corner of four, passes over none of them.
                let fx = x - x.rounded(.down), fy = y - y.rounded(.down)
                if fx < 0.05 || fx > 0.95 || fy < 0.05 || fy > 0.95 { continue }
                let cell = Cell(row: Int(y.rounded(.down)), column: Int(x.rounded(.down)))
                if cell != a && cell != b { cells.insert(cell) }
            }
            return cells
        }
        func reach(_ a: Cell, _ b: Cell) -> Int { max(abs(a.row - b.row), abs(a.column - b.column)) }
        // The links laid so far, each with the cells its straight run passes over.
        var laidLinks: [(cells: Set<Cell>, count: Int)] = []
        for item in order {
            let neighbors = weight[item] ?? [:]
            let waiting = neighbors.keys.filter { at[$0] == nil }.count
            let rows = (at.values.map(\.row).max() ?? -1) + 2
            var best: (cost: Double, cell: Cell)?
            for row in 0..<rows {
                for column in 0..<columns {
                    let cell = Cell(row: row, column: column)
                    guard taken[cell] == nil else { continue }
                    var cost = 0.0
                    for (neighbor, count) in neighbors {
                        guard let there = at[neighbor] else { continue }
                        let passes = under(cell, there).filter { taken[$0] != nil }.count
                        cost += Double(count) * (Double(max(0, reach(cell, there) - 1)) + 2 * Double(passes))
                    }
                    for link in laidLinks where link.cells.contains(cell) { cost += 2 * Double(link.count) }
                    if waiting > 0 {
                        var free = 0
                        for dr in -1...1 {
                            for dc in -1...1 where dr != 0 || dc != 0 {
                                let next = Cell(row: row + dr, column: column + dc)
                                if next.row >= 0, next.column >= 0, next.column < columns, taken[next] == nil { free += 1 }
                            }
                        }
                        cost -= 0.5 * Double(min(waiting, free))
                    }
                    if best == nil || cost < best!.cost - 1e-9 { best = (cost, cell) }
                }
            }
            guard let cell = best?.cell else { continue }
            at[item] = cell
            taken[cell] = item
            for (neighbor, count) in neighbors where neighbor != item { if let there = at[neighbor] { laidLinks.append((under(cell, there), count)) } }
        }
        let used = Set(at.values.map(\.column)).sorted()
        let height = (at.values.map(\.row).max() ?? -1) + 1
        var grid: [[Int?]] = []
        for row in 0..<height {
            let cells = used.map { column in taken[Cell(row: row, column: column)] }
            guard cells.contains(where: { $0 != nil }) else { continue }
            var trimmed = cells
            while trimmed.last == .some(nil) { trimmed.removeLast() }
            grid.append(trimmed)
        }
        return grid
    }
}
